import AVKit
import SwiftUI
import UIKit

struct AirPlayButton: View {
    var size: CGFloat = 24
    @State private var presenter = AirPlayPresenter()

    var body: some View {
        ZStack {
            AirPlayRoutePickerView(presenter: $presenter)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
                .opacity(0.0001)

            Button(
                action: { presenter.presentAirPlayPicker() },
                label: {
                    Image(systemName: "airplayaudio")
                        .font(.system(size: size))
                }
            )
        }
    }
}

private struct AirPlayRoutePickerView: UIViewRepresentable {
    @Binding var presenter: AirPlayPresenter

    func makeUIView(context _: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView(frame: .zero)
        view.prioritizesVideoDevices = false
        view.isHidden = true
        presenter.attach(routePickerView: view)
        return view
    }

    func updateUIView(_: AVRoutePickerView, context _: Context) {}
}

private final class AirPlayPresenter {
    private weak var routePickerView: AVRoutePickerView?

    func attach(routePickerView: AVRoutePickerView) {
        self.routePickerView = routePickerView
    }

    @MainActor
    func presentAirPlayPicker() {
        guard let routePickerView else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.presentAirPlayPicker()
            }
            return
        }
        if let internalButton = routePickerView.subviews.first(where: { $0 is UIButton }) as? UIButton {
            internalButton.sendActions(for: .touchUpInside)
        } else if let button = findButton(in: routePickerView) {
            button.sendActions(for: .touchUpInside)
        }
    }

    @MainActor private func findButton(in view: UIView) -> UIButton? {
        if let button = view as? UIButton { return button }
        for sub in view.subviews {
            if let found = findButton(in: sub) { return found }
        }
        return nil
    }
}
