import SwiftUI

/// A labeled slider with an editable value field. Right-click resets it to
/// its default; hovering shows what it does.
struct ParameterSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    let defaultValue: Double
    var unit: String? = nil
    /// The setting's name in settings files and Particles, shown in the tooltip.
    var key: String? = nil
    let help: String

    private var fractionDigits: Int {
        guard let step, step < 1 else { return step == nil ? 2 : 0 }
        return max(0, Int((-log10(step)).rounded(.up)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .accessibilityHidden(true)
                Spacer()
                TextField("", value: clamped, format: .number.precision(.fractionLength(fractionDigits)).grouping(.never))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 72)
                    .accessibilityLabel(unit.map { "\(title), \($0)" } ?? title)
                if let unit {
                    Text(unit).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            if let step {
                Slider(value: clamped, in: range, step: step)
                    .labelsHidden()
                    .accessibilityLabel(title)
                    .accessibilityValue(accessibilityValue)
                    .controlSize(.small)
            } else {
                Slider(value: clamped, in: range)
                    .labelsHidden()
                    .accessibilityLabel(title)
                    .accessibilityValue(accessibilityValue)
                    .controlSize(.small)
            }
        }
        .help(key.map { "\(help)\n\($0)" } ?? help)
        .contextMenu {
            Button("Reset to Default (\(defaultValue.formatted(.number.precision(.fractionLength(fractionDigits)))))") {
                value = defaultValue
            }
            .disabled(value == defaultValue)
        }
    }

    private var accessibilityValue: String {
        let number = value.formatted(.number.precision(.fractionLength(fractionDigits)))
        return unit.map { "\(number) \($0)" } ?? number
    }

    /// Typed values outside the slider's range are pulled back into it.
    private var clamped: Binding<Double> {
        Binding(get: { value }, set: { value = min(max($0, range.lowerBound), range.upperBound) })
    }
}

extension ParameterSlider {
    /// A slider over an integer value.
    init(title: String, value: Binding<Int>, range: ClosedRange<Int>, defaultValue: Int, unit: String? = nil,
         key: String? = nil, help: String) {
        self.init(
            title: title,
            value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0.rounded()) }),
            range: Double(range.lowerBound)...Double(range.upperBound),
            step: 1, defaultValue: Double(defaultValue), unit: unit, key: key, help: help)
    }
}

/// A strip showing each of a palette's colors.
struct PaletteSwatch: View {
    let colors: [SIMD3<Float>]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(colors.indices, id: \.self) { i in
                let c = colors[i]
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z)))
            }
        }
        .frame(height: 14)
        .accessibilityHidden(true)
    }
}

/// A short "1M" / "64K" label for a pool size.
func poolSizeLabel(_ size: Int) -> String {
    size >= 1 << 20 ? "\(size >> 20)M" : "\(size >> 10)K"
}
