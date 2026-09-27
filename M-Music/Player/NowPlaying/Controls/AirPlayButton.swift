import AVFoundation
import AVKit
import SwiftUI
import UIKit

struct AirPlayButton: View {
    var size: CGFloat = 24
    @State private var presenter = AirPlayPresenter()
    /// Which device audio is currently routed to — drives the glyph below, the same way Apple
    /// Music's own AirPlay button swaps its icon for the connected device instead of always
    /// showing the plain, unfilled AirPlay glyph.
    @State private var symbolName = Self.symbolName(for: AVAudioSession.sharedInstance().currentRoute.outputs.first)

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
                    Image(systemName: symbolName)
                        .font(.system(size: size))
                        .contentTransition(.symbolEffect(.replace))
                }
            )
        }
        // Only real way to find out the route changed — AVRoutePickerView itself never reports
        // the picked route back to us, and there's no @Published/Combine surface for it.
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in
            withAnimation {
                symbolName = Self.symbolName(for: AVAudioSession.sharedInstance().currentRoute.outputs.first)
            }
        }
    }

    /// Maps the active output route to the glyph that best represents it: the plain AirPlay glyph
    /// for the device's own speaker/receiver, and a device-specific glyph once audio is routed
    /// elsewhere — matched by name for AirPlay and Bluetooth outputs (`AVAudioSession` has no
    /// finer-grained port type than "airPlay" or "bluetoothA2DP" for e.g. a HomePod vs. a TV, or
    /// AirPods vs. some other Bluetooth speaker) and falling back to a generic glyph for whatever
    /// it doesn't recognize by name.
    private static func symbolName(for output: AVAudioSessionPortDescription?) -> String {
        guard let output else { return "airplayaudio" }
        let name = output.portName.lowercased()
        switch output.portType {
        case .builtInSpeaker, .builtInReceiver:
            return "airplayaudio"
        case .headphones:
            return "headphones"
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP:
            if name.contains("airpods max") { return "airpodsmax" }
            if name.contains("airpods pro") { return "airpodspro" }
            if name.contains("airpods") { return "airpods" }
            return "hifispeaker.fill"
        case .airPlay:
            if name.contains("homepod") { return "homepod.fill" }
            if name.contains("tv") { return "tv" }
            return "hifispeaker.fill"
        case .carAudio:
            return "car.fill"
        default:
            return "airplayaudio"
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
