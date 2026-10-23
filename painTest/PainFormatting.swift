import SwiftUI

enum PainFormatting {
    static func format(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return value.formatted(
            .number
                .precision(.fractionLength(0...1))
                .grouping(.never)
        )
    }

    static func formatDelta(_ value: Double) -> String {
        let prefix = value > 0 ? "+" : value < 0 ? "−" : ""
        return prefix + format(abs(value))
    }
}

struct PainValueLabel: View {
    let value: Double
    var size: PainValueSize = .body
    var showsUnit: Bool = true

    enum PainValueSize {
        case hero
        case body

        var valueFont: Font {
            switch self {
            case .hero:
                return .system(size: 40, weight: .semibold, design: .rounded)
            case .body:
                return .system(.body, design: .rounded).weight(.semibold)
            }
        }

        var unitFont: Font {
            switch self {
            case .hero:
                return .subheadline.weight(.medium)
            case .body:
                return .caption2.weight(.medium)
            }
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(PainFormatting.format(value))
                .font(size.valueFont)
                .monospacedDigit()
                .foregroundStyle(.primary)
                .contentTransition(.numericText())
                .animation(AppAnimations.chart, value: value)

            if showsUnit {
                Text("/ 10")
                    .font(size.unitFont)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct PainDeltaBadge: View {
    let delta: Double

    private var color: Color {
        if delta > 0 { return .red }
        if delta < 0 { return .green }
        return .secondary
    }

    private var arrow: String {
        if delta > 0 { return "↑" }
        if delta < 0 { return "↓" }
        return "—"
    }

    var body: some View {
        Text("\(arrow) \(PainFormatting.format(abs(delta)))")
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()
            .contentTransition(.numericText())
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
            .animation(AppAnimations.quick, value: delta)
    }
}
