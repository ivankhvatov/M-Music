import SwiftUI

struct ColorPoint: Hashable {
    var position: UnitPoint
    var color: Color
}

extension ColorPoint: Animatable {
    typealias AnimatableData = AnimatablePair<UnitPoint.AnimatableData, Color.Resolved.AnimatableData>

    var animatableData: ColorPoint.AnimatableData {
        get {
            ColorPoint.AnimatableData(
                position.animatableData,
                color.resolve(in: .init()).animatableData
            )
        }
        set {
            position = UnitPoint(newValue.first)
            color = Color(newValue.second)
        }
    }
}

extension ColorPoint {
    static var zero: ColorPoint {
        ColorPoint(position: .zero, color: .black.opacity(0))
    }

    /// Places this point at `index`'s slot in the golden-angle sequence (successive indices land
    /// ~137.5° apart around the center), rotated by a shared `rotationOffset` so the whole
    /// arrangement still looks different on every reshuffle.
    ///
    /// Fully independent random positions can land close together by chance — with only 3 real
    /// colors active at a time, that reads as the background collapsing toward a single
    /// near-solid color. The golden angle is the standard low-discrepancy trick for this: any
    /// prefix of the sequence (1, 2, 3, ... points) stays well spread, so it doesn't matter how
    /// many of the 8 slots actually carry a real color.
    static func spread(withColor color: Color, index: Int, rotationOffset: Double) -> ColorPoint {
        let goldenAngle = 137.50776
        let degrees = Double(index) * goldenAngle + rotationOffset + .random(in: -12 ... 12)
        let angle = degrees * .pi / 180
        let radius = CGFloat.random(in: 0.26 ... 0.44)
        let x = 0.5 + radius * cos(angle)
        let y = 0.5 + radius * sin(angle)
        return ColorPoint(
            position: UnitPoint(x: x.clamped(to: 0 ... 1), y: y.clamped(to: 0 ... 1)),
            color: color
        )
    }

    init(_ animatableData: ColorPoint.AnimatableData) {
        self.init(
            position: UnitPoint(animatableData.first),
            color: Color(animatableData.second)
        )
    }
}

private extension Color {
    init(_ animatableData: Color.Resolved.AnimatableData) {
        var resolvedColor = Color.Resolved(red: 0, green: 0, blue: 0)
        resolvedColor.animatableData = animatableData
        self.init(resolvedColor)
    }
}

private extension UnitPoint {
    static let animatableDataRatio =
        UnitPoint(x: 1, y: 1).animatableData.first / UnitPoint(x: 1, y: 1).x

    init(_ animatableData: UnitPoint.AnimatableData) {
        self.init(
            x: animatableData.first / UnitPoint.animatableDataRatio,
            y: animatableData.second / UnitPoint.animatableDataRatio
        )
    }
}

struct ColorPoints {
    let point0: ColorPoint
    let point1: ColorPoint
    let point2: ColorPoint
    let point3: ColorPoint
    let point4: ColorPoint
    let point5: ColorPoint
    let point6: ColorPoint
    let point7: ColorPoint
}

struct ColorPointsAnimatableData {
    var value0: ColorPoint.AnimatableData
    var value1: ColorPoint.AnimatableData
    var value2: ColorPoint.AnimatableData
    var value3: ColorPoint.AnimatableData
    var value4: ColorPoint.AnimatableData
    var value5: ColorPoint.AnimatableData
    var value6: ColorPoint.AnimatableData
    var value7: ColorPoint.AnimatableData
}

extension ColorPoints {
    init(points: [ColorPoint]) {
        self.init(
            point0: points[safe: 0] ?? .zero,
            point1: points[safe: 1] ?? .zero,
            point2: points[safe: 2] ?? .zero,
            point3: points[safe: 3] ?? .zero,
            point4: points[safe: 4] ?? .zero,
            point5: points[safe: 5] ?? .zero,
            point6: points[safe: 6] ?? .zero,
            point7: points[safe: 7] ?? .zero
        )
    }

    init(_ animatableData: ColorPointsAnimatableData) {
        self.init(
            point0: ColorPoint(animatableData.value0),
            point1: ColorPoint(animatableData.value1),
            point2: ColorPoint(animatableData.value2),
            point3: ColorPoint(animatableData.value3),
            point4: ColorPoint(animatableData.value4),
            point5: ColorPoint(animatableData.value5),
            point6: ColorPoint(animatableData.value6),
            point7: ColorPoint(animatableData.value7)
        )
    }

    static var zero: ColorPoints {
        ColorPoints(point0: .zero, point1: .zero, point2: .zero, point3: .zero, point4: .zero, point5: .zero, point6: .zero, point7: .zero)
    }

    var shuffled: ColorPoints {
        let rotationOffset = Double.random(in: 0 ..< 360)
        return ColorPoints(
            point0: .spread(withColor: point0.color, index: 0, rotationOffset: rotationOffset),
            point1: .spread(withColor: point1.color, index: 1, rotationOffset: rotationOffset),
            point2: .spread(withColor: point2.color, index: 2, rotationOffset: rotationOffset),
            point3: .spread(withColor: point3.color, index: 3, rotationOffset: rotationOffset),
            point4: .spread(withColor: point4.color, index: 4, rotationOffset: rotationOffset),
            point5: .spread(withColor: point5.color, index: 5, rotationOffset: rotationOffset),
            point6: .spread(withColor: point6.color, index: 6, rotationOffset: rotationOffset),
            point7: .spread(withColor: point7.color, index: 7, rotationOffset: rotationOffset)
        )
    }

    func colored(colors: [Color]) -> ColorPoints {
        ColorPoints(
            point0: ColorPoint(position: point0.position, color: colors[safe: 0] ?? .black.opacity(0)),
            point1: ColorPoint(position: point1.position, color: colors[safe: 1] ?? .black.opacity(0)),
            point2: ColorPoint(position: point2.position, color: colors[safe: 2] ?? .black.opacity(0)),
            point3: ColorPoint(position: point3.position, color: colors[safe: 3] ?? .black.opacity(0)),
            point4: ColorPoint(position: point4.position, color: colors[safe: 4] ?? .black.opacity(0)),
            point5: ColorPoint(position: point5.position, color: colors[safe: 5] ?? .black.opacity(0)),
            point6: ColorPoint(position: point6.position, color: colors[safe: 6] ?? .black.opacity(0)),
            point7: ColorPoint(position: point7.position, color: colors[safe: 7] ?? .black.opacity(0))
        )
    }
}

extension ColorPoints: Animatable {
    var animatableData: ColorPointsAnimatableData {
        get { ColorPointsAnimatableData(self) }
        set { self = ColorPoints(newValue) }
    }
}

extension ColorPointsAnimatableData {
    init(_ colorPoints: ColorPoints) {
        self.init(
            value0: colorPoints.point0.animatableData,
            value1: colorPoints.point1.animatableData,
            value2: colorPoints.point2.animatableData,
            value3: colorPoints.point3.animatableData,
            value4: colorPoints.point4.animatableData,
            value5: colorPoints.point5.animatableData,
            value6: colorPoints.point6.animatableData,
            value7: colorPoints.point7.animatableData
        )
    }
}

extension ColorPointsAnimatableData: VectorArithmetic {
    static func - (lhs: ColorPointsAnimatableData, rhs: ColorPointsAnimatableData) -> ColorPointsAnimatableData {
        ColorPointsAnimatableData(
            value0: lhs.value0 - rhs.value0,
            value1: lhs.value1 - rhs.value1,
            value2: lhs.value2 - rhs.value2,
            value3: lhs.value3 - rhs.value3,
            value4: lhs.value4 - rhs.value4,
            value5: lhs.value5 - rhs.value5,
            value6: lhs.value6 - rhs.value6,
            value7: lhs.value7 - rhs.value7
        )
    }

    static func + (lhs: ColorPointsAnimatableData, rhs: ColorPointsAnimatableData) -> ColorPointsAnimatableData {
        ColorPointsAnimatableData(
            value0: lhs.value0 + rhs.value0,
            value1: lhs.value1 + rhs.value1,
            value2: lhs.value2 + rhs.value2,
            value3: lhs.value3 + rhs.value3,
            value4: lhs.value4 + rhs.value4,
            value5: lhs.value5 + rhs.value5,
            value6: lhs.value6 + rhs.value6,
            value7: lhs.value7 + rhs.value7
        )
    }

    mutating func scale(by rhs: Double) {
        value0 = value0.scaled(by: rhs)
        value1 = value1.scaled(by: rhs)
        value2 = value2.scaled(by: rhs)
        value3 = value3.scaled(by: rhs)
        value4 = value4.scaled(by: rhs)
        value5 = value5.scaled(by: rhs)
        value6 = value6.scaled(by: rhs)
        value7 = value7.scaled(by: rhs)
    }

    var magnitudeSquared: Double {
        value0.magnitudeSquared + value1.magnitudeSquared + value2.magnitudeSquared + value3.magnitudeSquared
            + value4.magnitudeSquared + value5.magnitudeSquared + value6.magnitudeSquared + value7.magnitudeSquared
    }

    static var zero: ColorPointsAnimatableData {
        ColorPointsAnimatableData(value0: .zero, value1: .zero, value2: .zero, value3: .zero, value4: .zero, value5: .zero, value6: .zero, value7: .zero)
    }
}
