import SwiftUI
import Charts

/// Chart helpers live here; the app tab is `LogView` (History + Trends).
struct TrendsView: View {
    var body: some View {
        LogView()
    }
}

struct RangePicker: View {
    @Binding var range: PainStore.TrendRange

    var body: some View {
        HStack {
            Text("Estimated PSPI")
                .font(.headline)
            Spacer()
            Picker("Range", selection: $range) {
                ForEach(PainStore.TrendRange.allCases) { r in
                    Text(r.title).tag(r)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 260)
        }
        .animation(AppAnimations.quick, value: range)
    }
}

struct TrendChart: View {
    @EnvironmentObject var store: PainStore
    let range: PainStore.TrendRange
    let filter: PainStore.TrendFilter

    private var data: [AnalysisSession] {
        store.sessions(in: range, filter: filter)
    }

    private var yDomain: ClosedRange<Double> {
        0...16
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Chart(data) { session in
                AreaMark(
                    x: .value("Date", session.date),
                    yStart: .value("PSPI", yDomain.lowerBound),
                    yEnd: .value("PSPI", session.pspi)
                )
                .interpolationMethod(.linear)
                .foregroundStyle(
                    LinearGradient(
                        colors: [.cyan.opacity(0.45), .indigo.opacity(0.08)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                LineMark(
                    x: .value("Date", session.date),
                    y: .value("PSPI", session.pspi)
                )
                .interpolationMethod(.linear)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                .foregroundStyle(.indigo)

                PointMark(
                    x: .value("Date", session.date),
                    y: .value("PSPI", session.pspi)
                )
                .symbolSize(data.count <= 3 ? 110 : 85)
                .foregroundStyle(session.passedStrictChecks ? Color.indigo : Color.orange)

                PointMark(
                    x: .value("Date", session.date),
                    y: .value("PSPI", session.pspi)
                )
                .symbolSize(data.count <= 3 ? 50 : 40)
                .foregroundStyle(.white)
            }
            .chartYScale(domain: yDomain)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4))
            }
            .chartYAxis {
                AxisMarks(values: [0, 4, 8, 12, 16])
            }
            .animation(AppAnimations.chart, value: data.map(\.id))
            .frame(height: 240)

            if filter.includeLowConfidence, data.contains(where: { !$0.passedStrictChecks }) {
                Label("Orange points are low-confidence captures", systemImage: "circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding()
        .animatedCard()
    }
}

struct TrendStats: View {
    @EnvironmentObject var store: PainStore
    let range: PainStore.TrendRange
    let filter: PainStore.TrendFilter

    var body: some View {
        guard let stats = store.sessionStats(for: range, filter: filter) else {
            return AnyView(
                Text("No successful captures in this range.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .animatedCard()
            )
        }

        let change = stats.change
        let changeLabel: String = {
            if abs(change) < 0.05 { return "No change" }
            let arrow = change > 0 ? "↑" : "↓"
            return "\(arrow) \(String(format: "%.1f", abs(change)))"
        }()

        return AnyView(
            HStack(spacing: 12) {
                StatCard(
                    title: "Highest",
                    value: String(format: "%.1f / 16", stats.max),
                    detail: "Across \(stats.count) \(stats.count == 1 ? "capture" : "captures")"
                )
                .staggeredAppear(index: 0)
                StatCard(
                    title: "Lowest",
                    value: String(format: "%.1f / 16", stats.min),
                    detail: "\(stats.firstDate.formatted(date: .abbreviated, time: .omitted)) – \(stats.lastDate.formatted(date: .abbreviated, time: .omitted))"
                )
                .staggeredAppear(index: 1)
                StatCard(
                    title: "Average & trend",
                    value: String(format: "%.1f / 16", stats.avg),
                    detail: "Selected range: \(changeLabel)"
                )
                .staggeredAppear(index: 2)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .animatedCard()
            .animation(AppAnimations.chart, value: range)
        )
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .contentTransition(.numericText())
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    TrendsView()
        .environmentObject(PainStore())
}
