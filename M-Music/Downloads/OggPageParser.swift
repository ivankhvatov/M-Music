import Foundation

/// A minimal, from-scratch Ogg (RFC 3533) page/packet parser scoped to exactly what
/// `OpusToCAFRemuxer` needs for an Ogg Opus (RFC 7845) stream. No Apple framework parses Ogg —
/// this only ever walks framing bytes; it never touches, decodes, or re-encodes the audio itself.
enum OggPageParser {
    struct OpusHead {
        let channelCount: UInt8
        let preSkip: UInt16
        let channelMappingFamily: UInt8
    }

    struct Packet {
        let data: Data
    }

    struct ParsedStream {
        let head: OpusHead
        /// Audio packets only — the `OpusHead`/`OpusTags` packets are consumed internally and
        /// excluded here.
        let packets: [Packet]
        /// Granule position of the last page belonging to this stream — total samples at Opus's
        /// fixed 48kHz clock, including pre-skip and trailing padding (RFC 7845 §4.4).
        let finalGranulePosition: Int64
    }

    enum ParseError: LocalizedError {
        case notOgg
        case missingOpusHead
        case unsupportedChannelMapping
        case truncatedOrMalformed

        var errorDescription: String? {
            switch self {
            case .notOgg: return "Not an Ogg container"
            case .missingOpusHead: return "First Ogg packet is not an OpusHead (likely Vorbis, not Opus)"
            case .unsupportedChannelMapping: return "Opus channel mapping family is not mono/stereo (family 0)"
            case .truncatedOrMalformed: return "Ogg stream is truncated or malformed"
            }
        }
    }

    static func parse(data: Data) throws -> ParsedStream {
        let bytes = [UInt8](data)
        guard bytes.count >= 27, bytes[0..<4].elementsEqual(Array("OggS".utf8)) else {
            throw ParseError.notOgg
        }

        var streamSerial: UInt32?
        var packetAccumulator: [UInt8] = []
        var packets: [Packet] = []
        var head: OpusHead?
        var sawTags = false
        var finalGranulePosition: Int64 = 0

        var pos = 0
        while pos < bytes.count {
            guard pos + 27 <= bytes.count, bytes[pos..<pos + 4].elementsEqual(Array("OggS".utf8)) else {
                throw ParseError.truncatedOrMalformed
            }
            let headerType = bytes[pos + 5]
            let isContinuation = headerType & 0x01 != 0
            let granulePosition = readInt64LE(bytes, at: pos + 6)
            let serial = readUInt32LE(bytes, at: pos + 14)
            let segmentCount = Int(bytes[pos + 26])
            let segmentTableStart = pos + 27
            guard segmentTableStart + segmentCount <= bytes.count else { throw ParseError.truncatedOrMalformed }
            let segmentTable = bytes[segmentTableStart..<segmentTableStart + segmentCount]
            var dataPos = segmentTableStart + segmentCount
            let pageDataLength = segmentTable.reduce(0) { $0 + Int($1) }

            if let streamSerial, streamSerial != serial {
                // A different logical stream multiplexed into the same file — skip its page
                // entirely without touching our accumulator.
                pos = dataPos + pageDataLength
                continue
            }
            if streamSerial == nil { streamSerial = serial }

            if !packetAccumulator.isEmpty && !isContinuation {
                throw ParseError.truncatedOrMalformed
            }

            for lacingValue in segmentTable {
                let segmentEnd = dataPos + Int(lacingValue)
                guard segmentEnd <= bytes.count else { throw ParseError.truncatedOrMalformed }
                packetAccumulator.append(contentsOf: bytes[dataPos..<segmentEnd])
                dataPos = segmentEnd
                if lacingValue < 255 {
                    try consumePacket(
                        Data(packetAccumulator), head: &head, sawTags: &sawTags, packets: &packets
                    )
                    packetAccumulator.removeAll(keepingCapacity: true)
                }
                // lacingValue == 255 means the packet continues (into the next segment, or the
                // next page if this was the page's last segment) — keep accumulating.
            }

            finalGranulePosition = granulePosition
            pos = dataPos
        }

        guard let head else { throw ParseError.missingOpusHead }
        guard head.channelMappingFamily == 0 else { throw ParseError.unsupportedChannelMapping }
        return ParsedStream(head: head, packets: packets, finalGranulePosition: finalGranulePosition)
    }

    private static func consumePacket(
        _ packet: Data, head: inout OpusHead?, sawTags: inout Bool, packets: inout [Packet]
    ) throws {
        if head == nil {
            guard packet.count >= 19, packet.starts(with: Array("OpusHead".utf8)) else {
                throw ParseError.missingOpusHead
            }
            let bytes = [UInt8](packet)
            let channelCount = bytes[9]
            let preSkip = UInt16(bytes[10]) | (UInt16(bytes[11]) << 8)
            let channelMappingFamily = bytes[18]
            head = OpusHead(channelCount: channelCount, preSkip: preSkip, channelMappingFamily: channelMappingFamily)
            return
        }
        if !sawTags {
            sawTags = true
            return
        }
        packets.append(Packet(data: packet))
    }

    private static func readUInt32LE(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func readInt64LE(_ bytes: [UInt8], at offset: Int) -> Int64 {
        var value: UInt64 = 0
        for i in (0..<8).reversed() {
            value = (value << 8) | UInt64(bytes[offset + i])
        }
        return Int64(bitPattern: value)
    }
}
