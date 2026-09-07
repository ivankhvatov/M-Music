import AVFoundation
import MediaPlayer
import SwiftUI

/// A volume slider styled like the playback scrubber, driving the system volume through a
/// hidden `MPVolumeView` so it stays in sync with the hardware buttons and Control Center.
struct VolumeSlider: View {
    @State private var minVolumeAnimationTrigger = false
    @State private var maxVolumeAnimationTrigger = false
    let range = 0.0 ... 1
    @StateObject private var viewModel = VolumeSliderViewModel()

    var body: some View {
        ZStack {
            MPVolumeViewWrapper(proxy: viewModel.volumeViewProxy)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)

            ElasticSlider(
                value: $viewModel.currentVolume,
                in: range,
                leadingLabel: {
                    Image(systemName: "speaker.fill")
                        .padding(.trailing, 10)
                        .symbolEffect(.bounce, value: minVolumeAnimationTrigger)
                },
                trailingLabel: {
                    Image(systemName: "speaker.wave.3.fill")
                        .padding(.leading, 10)
                        .symbolEffect(.bounce, value: maxVolumeAnimationTrigger)
                },
                onValueChanged: { [weak viewModel] in viewModel?.setVolume($0) },
                onActive: { [weak viewModel] in viewModel?.setSliderActive($0) }
            )
            .sliderStyle(.volume)
            .font(.system(size: 14))
            .onChange(of: viewModel.currentVolume) {
                if viewModel.currentVolume == range.lowerBound {
                    minVolumeAnimationTrigger.toggle()
                }
                if viewModel.currentVolume == range.upperBound {
                    maxVolumeAnimationTrigger.toggle()
                }
            }
            .frame(height: 50)
        }
    }
}

extension ElasticSliderConfig {
    static var volume: Self {
        Self(
            labelLocation: .side,
            maxStretch: 10,
            minimumTrackActiveColor: .white,
            minimumTrackInactiveColor: .white.opacity(0.6),
            maximumTrackColor: .white.opacity(0.6),
            blendMode: .overlay,
            syncLabelsStyle: true
        )
    }
}

final class MPVolumeViewProxy {
    var mpVolumeView: MPVolumeView?
}

private struct MPVolumeViewWrapper: UIViewRepresentable {
    var proxy: MPVolumeViewProxy

    func makeUIView(context _: Context) -> MPVolumeView {
        let mpView = MPVolumeView()
        proxy.mpVolumeView = mpView
        mpView.alpha = 0.0001
        mpView.isUserInteractionEnabled = false
        mpView.clipsToBounds = true
        return mpView
    }

    func updateUIView(_ uiView: MPVolumeView, context _: Context) {
        uiView.alpha = 0.0001
        uiView.isUserInteractionEnabled = false
    }
}

@MainActor
final class VolumeSliderViewModel: ObservableObject {
    @Published var currentVolume: Double = 0.0
    private var audioSession = AVAudioSession.sharedInstance()
    private var volumeObservation: NSKeyValueObservation?
    private var isSliderActive = false
    let volumeViewProxy = MPVolumeViewProxy()

    init() {
        currentVolume = Double(audioSession.outputVolume)
        observeVolumeChanges()
    }

    private func observeVolumeChanges() {
        volumeObservation = audioSession.observe(\.outputVolume, options: [.new, .initial]) { [weak self] _, change in
            guard let self, let newVolume = change.newValue else { return }
            Task { @MainActor [weak self] in
                guard let self, !self.isSliderActive else { return }
                let value = Double(newVolume)
                if abs(currentVolume - value) > 0.001 {
                    withAnimation { self.currentVolume = value }
                }
            }
        }
    }

    func setVolume(_ volume: Double) {
        guard let mpVolumeView = volumeViewProxy.mpVolumeView,
              let slider = mpVolumeView.subviews.first(where: { $0 is UISlider }) as? UISlider
        else { return }
        if abs(slider.value - Float(volume)) > 0.001 {
            slider.setValue(Float(volume), animated: false)
        }
    }

    func setSliderActive(_ isActive: Bool) {
        isSliderActive = isActive
    }

    deinit {
        volumeObservation?.invalidate()
    }
}
