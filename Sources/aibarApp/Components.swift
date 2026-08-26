import SwiftUI
import AibarCore

/// 小节标题
///
/// 参数刻意用 `LocalizedStringKey` 而不是 `String`：
/// `Text(String)` **不做本地化**，只有 `Text(LocalizedStringKey)` 才会查表。
/// 组件收 String 会让所有调用点静默失去翻译。
struct SectionLabel: View {
    let text: LocalizedStringKey
    var trailing: String?

    var body: some View {
        HStack {
            Text(text)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.tertiary)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 10))
                    .foregroundStyle(.quaternary)
            }
        }
    }
}

/// 额度环。用真实百分比画，拿不到就不画。
struct QuotaRing: View {
    let percent: Double
    let tint: Color
    var size: CGFloat = 46
    var lineWidth: CGFloat = 5

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(1, max(0, percent / 100)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(Fmt.percent(percent))
                .font(.system(size: size * 0.26, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(L("已用 %@", Fmt.percent(percent)))
    }
}

/// 预算环。
///
/// 刻意用分段虚线画底，和额度环的实心底区分开 ——
/// 一个是厂商给的额度，一个是你自己定的花费上限，不该长得一样。
struct BudgetRing: View {
    let percent: Double
    let tint: Color
    var size: CGFloat = 46

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, style: StrokeStyle(lineWidth: 5, dash: [2, 3]))
            Circle()
                .trim(from: 0, to: min(1, max(0, percent / 100)))
                .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .butt))
                .rotationEffect(.degrees(-90))
            Text(Fmt.percent(percent))
                .font(.system(size: size * 0.26, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(L("预算已用 %@", Fmt.percent(percent)))
    }
}

/// 未连接时的空环。虚线是刻意的 —— 它读起来就不像一个“0%”。
struct EmptyRing: View {
    var size: CGFloat = 46

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, style: StrokeStyle(lineWidth: 5, dash: [3, 4]))
            Text("—").font(.system(size: size * 0.3)).foregroundStyle(.tertiary)
        }
        .frame(width: size, height: size)
    }
}

/// 单条占比轨
struct MiniBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(tint)
                    .frame(width: max(fraction > 0 ? 2 : 0, geo.size.width * min(1, fraction)))
            }
        }
        .frame(height: 3)
        // 纯装饰：数值已经在同一行的文字里念过了，再念一遍是噪音
        .accessibilityHidden(true)
    }
}

/// 14 天堆叠柱。零用量的那天画一条基线，而不是留空 —— 空白读不出“那天没跑”。
struct DailyChart: View {
    let points: [Snapshot.DayPoint]
    var height: CGFloat = 42

    private var maxTotal: Int { max(1, points.map(\.total).max() ?? 1) }

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(points) { point in
                VStack(spacing: 1) {
                    Spacer(minLength: 0)
                    if point.total == 0 {
                        Rectangle().fill(.quaternary).frame(height: 1)
                    } else {
                        ForEach(Provider.allCases, id: \.self) { p in
                            let v = point.byProvider[p] ?? 0
                            if v > 0 {
                                Rectangle()
                                    .fill(p.tint)
                                    .frame(height: max(1, height * CGFloat(v) / CGFloat(maxTotal)))
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .help("\(point.day.formatted(.dateTime.month().day()))　\(Fmt.tokens(point.total))")
            }
        }
        .frame(height: height)
        // 柱状图对 VoiceOver 是完全不可读的。合并成一个元素并给出摘要，
        // 比让读屏逐个念 14 个无标签矩形有用得多。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("近 14 天用量趋势"))
        .accessibilityValue(chartSummary)
    }

    private var chartSummary: String {
        let active = points.filter { $0.total > 0 }
        guard let peak = points.max(by: { $0.total < $1.total }), peak.total > 0 else {
            return L("这段时间没有用量")
        }
        return L("%lld 天有用量，最高 %@ 于 %@",
                 active.count, Fmt.tokens(peak.total),
                 peak.day.formatted(.dateTime.month().day()))
    }
}

/// 面板里的按钮。刻意做得比系统按钮更紧凑，352pt 宽塞不下标准控件。
struct PanelButton: View {
    let title: LocalizedStringKey
    var systemImage: String?
    var prominent = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 10)) }
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(prominent ? Color.accentColor.opacity(hovering ? 1 : 0.9)
                                    : Color.primary.opacity(hovering ? 0.12 : 0.06))
            )
            .foregroundStyle(prominent ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(.isButton)
    }
}
