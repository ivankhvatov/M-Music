import SwiftUI

struct MulticolorGradient: View, Animatable {
    let library = ShaderLibrary.default
    var points: ColorPoints
    var animationUpdateHandler: ((ColorPoints) -> Void)?

    var uniforms: Uniforms {
        Uniforms(params: GradientParams(points: points, bias: 0.05, power: 2.5, noise: 2))
    }

    var animatableData: ColorPointsAnimatableData {
        get {
            points.animatableData
        }
        set {
            points = ColorPoints(newValue)
            animationUpdateHandler?(points)
        }
    }

    var body: some View {
        Rectangle()
            .colorEffect(
                library.gradient(.boundingRect, .uniforms(uniforms))
            )
    }
}

private extension Shader.Argument {
    static func uniforms(_ param: Uniforms) -> Shader.Argument {
        var copy = param
        return .data(Data(bytes: &copy, count: MemoryLayout<Uniforms>.stride))
    }
}
