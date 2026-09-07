import Foundation

@inline(__always)
func lerp<V: BinaryFloatingPoint>(_ v0: V, _ v1: V, _ t: some BinaryFloatingPoint) -> V {
    v0 + V(t) * (v1 - v0)
}

extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}

extension ClosedRange where Bound: AdditiveArithmetic {
    var distance: Bound {
        upperBound - lowerBound
    }
}

extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
