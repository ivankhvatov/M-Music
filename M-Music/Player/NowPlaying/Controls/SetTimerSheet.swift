import SwiftUI

/// The sheet behind the player's "Set timer": hours, minutes and seconds on three wheels that share
/// one selection capsule, what to do when the time is up, and a "Start" button. Starting with the time
/// at zero just closes the sheet.
///
/// Starting is the presenter's business (`onStart`, given the seconds and what to do after them); the
/// sheet closes itself either way.
struct SetTimerSheet: View {
    let onStart: (TimeInterval, SleepTimer.Completion) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var hours = 0
    @State private var minutes = 0
    @State private var seconds = 0
    @State private var completion = SleepTimer.Completion.stopImmediately

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                TimerWheels(hours: $hours, minutes: $minutes, seconds: $seconds)
                    .frame(height: 216)
                completionMenu
                Button {
                    start()
                } label: {
                    Text("Start")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .navigationTitle("Set timer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
            }
        }
        .presentationDetents([.height(460)])
        .presentationDragIndicator(.visible)
    }

    /// "Upon completion", with what's chosen beside it, opening a menu of the choices.
    private var completionMenu: some View {
        HStack {
            Text("Upon completion")
                .lineLimit(1)
            Spacer(minLength: 12)
            Picker("Upon completion", selection: $completion) {
                Text("Stop immediately").tag(SleepTimer.Completion.stopImmediately)
                Text("Finish current song").tag(SleepTimer.Completion.finishSong)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 4)
    }

    private func start() {
        let total = TimeInterval(hours * 3600 + minutes * 60 + seconds)
        if total > 0 { onStart(total, completion) }
        dismiss()
    }
}

/// Three number wheels — hours, minutes, seconds — in a single `UIPickerView`. One picker with three
/// components draws one selection capsule across all of them; three separate SwiftUI wheel pickers
/// draw a capsule each.
private struct TimerWheels: UIViewRepresentable {
    @Binding var hours: Int
    @Binding var minutes: Int
    @Binding var seconds: Int

    /// Width of each wheel.
    static let componentWidth: CGFloat = 88
    /// Room kept free right of the numbers, which are right-aligned in their wheel, for the unit.
    static let numberTrailingInset: CGFloat = 38
    /// Between a number's right edge and its unit.
    static let unitGap: CGFloat = 6
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIPickerView {
        let picker = TimerPicker()
        picker.dataSource = context.coordinator
        picker.delegate = context.coordinator
        picker.selectRow(hours, inComponent: 0, animated: false)
        picker.selectRow(minutes, inComponent: 1, animated: false)
        picker.selectRow(seconds, inComponent: 2, animated: false)
        return picker
    }

    func updateUIView(_ picker: UIPickerView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, UIPickerViewDataSource, UIPickerViewDelegate {
        var parent: TimerWheels

        init(_ parent: TimerWheels) { self.parent = parent }

        func numberOfComponents(in pickerView: UIPickerView) -> Int { 3 }

        func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
            component == 0 ? 24 : 60
        }

        func pickerView(_ pickerView: UIPickerView, widthForComponent component: Int) -> CGFloat {
            TimerWheels.componentWidth
        }

        func pickerView(_ pickerView: UIPickerView, viewForRow row: Int, forComponent component: Int, reusing view: UIView?) -> UIView {
            let label = (view as? NumberLabel) ?? NumberLabel()
            label.text = "\(row)"
            label.font = .systemFont(ofSize: 23)
            label.textAlignment = .right
            return label
        }

        func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) {
            switch component {
            case 0: parent.hours = row
            case 1: parent.minutes = row
            default: parent.seconds = row
            }
        }
    }
}

/// A wheel row's number, right-aligned with `TimerWheels.numberTrailingInset` kept free after it.
private final class NumberLabel: UILabel {
    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: UIEdgeInsets(top: 0, left: 0, bottom: 0, right: TimerWheels.numberTrailingInset)))
    }
}

/// The wheels, with each unit label put right after its wheel's selected number. They're placed from
/// where the picker actually draws the numbers, so the gap is the same on all three whatever the
/// picker's own spacing between wheels.
private final class TimerPicker: UIPickerView {
    private let unitLabels: [UILabel] = [
        String(localized: "hours"), String(localized: "min"), String(localized: "sec"),
    ].map { unit in
        let label = UILabel()
        label.text = unit
        label.font = UIFont.preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
        label.sizeToFit()
        return label
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        unitLabels.forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        for (component, label) in unitLabels.enumerated() {
            guard let row = view(forRow: selectedRow(inComponent: component), forComponent: component) else { continue }
            let frame = row.convert(row.bounds, to: self)
            label.frame.origin = CGPoint(
                x: frame.maxX - TimerWheels.numberTrailingInset + TimerWheels.unitGap,
                y: bounds.midY - label.bounds.height / 2
            )
            bringSubviewToFront(label)
        }
    }

    override func selectRow(_ row: Int, inComponent component: Int, animated: Bool) {
        super.selectRow(row, inComponent: component, animated: animated)
        setNeedsLayout()
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        UIFont.systemFont(ofSize: pointSize, weight: weight)
    }
}
