import SwiftUI
import Charts
import AibarCore

/// 每日堆叠柱。三家配色与面板、会话列表保持一致，
/// 用户不必反复回看图例。
struct TrendChart: View {
    let series: [Snapshot.DayPoint]
    let metric: DashboardModel.Metric
    /// 成本按天的近似：这里只画 token，成本走另一条路径传入
    var costByDay: [Date: Double] = [:]

    private struct Bar: Identifiable {
        let id = UUID()
        let day: Date
        let provider: Provider
        let value: Double
    }

    private var bars: [Bar] {
        series.flatMap { point in
            Provider.allCases.compactMap { p in
                let tokens = point.byProvider[p] ?? 0
                guard tokens > 0 else { return nil }
                return Bar(day: point.day, provider: p, value: Double(tokens))
            }
        }
    }

    var body: some View {
        Chart(bars) { bar in
            BarMark(
                x: .value("日期", bar.day, unit: .day),
                y: .value(metric.title, bar.value)
            )
            .foregroundStyle(by: .value("来源", bar.provider.displayName))
            .cornerRadius(1.5)
        }
        .chartForegroundStyleScale([
            Provider.claudeCode.displayName: Provider.claudeCode.tint,
            Provider.codex.displayName: Provider.codex.tint,
            Provider.grok.displayName: Provider.grok.tint,
        ])
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text(Fmt.tokens(Int(v))) }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 7)) { _ in
                AxisGridLine().foregroundStyle(.quaternary.opacity(0.4))
                AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
            }
        }
        .chartLegend(position: .top, alignment: .trailing, spacing: 10)
    }
}

/// 排行条。横向条形比饼图更容易比长度，也放得下长模型名。
struct RankBars: View {
    let buckets: [Reports.Bucket]
    let model: DashboardModel
    var limit = 8
    var tintFor: (Reports.Bucket) -> Color

    private var shown: [Reports.Bucket] { Array(buckets.prefix(limit)) }
    private var maxValue: Double { max(1, shown.map { model.value($0) }.max() ?? 1) }

    var body: some View {
        VStack(spacing: 7) {
            ForEach(shown, id: \.key) { bucket in
                HStack(spacing: 10) {
                    Text(displayKey(bucket))
                        .font(.system(size: 11.5))
                        .lineLimit(1).truncationMode(.middle)
                        .frame(width: 150, alignment: .leading)

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary.opacity(0.5))
                            Capsule().fill(tintFor(bucket))
                                .frame(width: max(3, geo.size.width * model.value(bucket) / maxValue))
                        }
                    }
                    .frame(height: 8)

                    Text(model.formatted(bucket))
                        .font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 72, alignment: .trailing)

                    Text("\(bucket.sessions)")
                        .font(.system(size: 10)).monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .frame(width: 34, alignment: .trailing)
                }
            }
            if buckets.count > limit {
                Text("另有 \(buckets.count - limit) 项")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func displayKey(_ b: Reports.Bucket) -> String {
        Provider(rawValue: b.key)?.displayName ?? b.key
    }
}

/// 单个会话的逐轮曲线
struct TimelineChart: View {
    let points: [TurnPoint]

    var body: some View {
        if points.count < 2 {
            Text("该会话只有 \(points.count) 轮，画不出曲线")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, minHeight: 90)
        } else {
            Chart(points) { point in
                AreaMark(
                    x: .value("时间", point.timestamp),
                    y: .value("Token", point.tokens)
                )
                .foregroundStyle(.linearGradient(
                    colors: [.accentColor.opacity(0.30), .accentColor.opacity(0.02)],
                    startPoint: .top, endPoint: .bottom))
                LineMark(
                    x: .value("时间", point.timestamp),
                    y: .value("Token", point.tokens)
                )
                .foregroundStyle(Color.accentColor)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel {
                        if let v = value.as(Double.self) { Text(Fmt.tokens(Int(v))) }
                    }
                }
            }
            .frame(height: 110)
        }
    }
}
