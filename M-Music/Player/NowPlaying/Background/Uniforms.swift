import simd
import SwiftUI

struct Uniforms {
    let pointCount: simd_int1

    let bias: simd_float1
    let power: simd_float1
    let noise: simd_float1

    let point0: simd_float2
    let point1: simd_float2
    let point2: simd_float2
    let point3: simd_float2
    let point4: simd_float2
    let point5: simd_float2
    let point6: simd_float2
    let point7: simd_float2

    let color0: simd_float4
    let color1: simd_float4
    let color2: simd_float4
    let color3: simd_float4
    let color4: simd_float4
    let color5: simd_float4
    let color6: simd_float4
    let color7: simd_float4
}

struct GradientParams {
    let points: ColorPoints
    let bias: Float
    let power: Float
    let noise: Float
}

extension Uniforms {
    init(params: GradientParams) {
        self.init(
            pointCount: 8,
            bias: params.bias,
            power: params.power,
            noise: params.noise,
            point0: params.points.point0.position.simd,
            point1: params.points.point1.position.simd,
            point2: params.points.point2.position.simd,
            point3: params.points.point3.position.simd,
            point4: params.points.point4.position.simd,
            point5: params.points.point5.position.simd,
            point6: params.points.point6.position.simd,
            point7: params.points.point7.position.simd,
            color0: params.points.point0.color.simd,
            color1: params.points.point1.color.simd,
            color2: params.points.point2.color.simd,
            color3: params.points.point3.color.simd,
            color4: params.points.point4.color.simd,
            color5: params.points.point5.color.simd,
            color6: params.points.point6.color.simd,
            color7: params.points.point7.color.simd
        )
    }
}

private extension UnitPoint {
    var simd: simd_float2 { simd_float2(Float(x), Float(y)) }
}

private extension Color {
    /// `MulticolorGradient.uniforms` rebuilds a fresh `Uniforms` — and so re-resolves every
    /// point's `simd` here — on every single frame of `ColorfulBackgroundModel`'s continuous 40s
    /// reshuffle animation, for as long as the player sits expanded. Reshuffling only ever moves
    /// a point's *position* (`ColorPoints.shuffled` keeps each point's own `color` unchanged), so
    /// the exact same `Color` gets bridged through `UIColor(self).getRed(...)` over and over —
    /// real, measured CPU cost (ObjC bridging, 8 points, every frame) for a value that never
    /// actually changes between those frames. Caching by the `Color` value itself (`Color` is
    /// `Hashable`) turns every repeat into a dictionary lookup; the cache only grows with how many
    /// *distinct* colors a listening session ever shows (dozens at most — one per track's
    /// extracted palette), trivial memory for a real, continuous CPU win.
    static var simdCache: [Color: simd_float4] = [:]

    var simd: simd_float4 {
        if let cached = Self.simdCache[self] { return cached }
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        UIColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let value = simd_float4(Float(red), Float(green), Float(blue), Float(alpha))
        Self.simdCache[self] = value
        return value
    }
}
