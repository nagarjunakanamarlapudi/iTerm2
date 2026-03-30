import SwiftUI

// MARK: - Mission Control Design System
// Single source of truth for all dashboard colors, spacing, typography.
// Replaces the duplicated Dash/ADash enums across DashboardView, SessionsView, AnalyticsView.

enum MC {

    // MARK: - Colors — Layered backgrounds (deep space, 3 elevation levels)

    static let bgDeep    = Color(red: 0x08/255, green: 0x0A/255, blue: 0x10/255)  // deepest layer
    static let bgBase    = Color(red: 0x0C/255, green: 0x0E/255, blue: 0x14/255)  // panel background
    static let bgSurface = Color(red: 0x14/255, green: 0x17/255, blue: 0x20/255)  // card/section surface
    static let bgElevated = Color(red: 0x1C/255, green: 0x20/255, blue: 0x2C/255) // hovered/selected card

    // MARK: - Text hierarchy (WCAG AA compliant on bgSurface)

    static let textHero      = Color.white                                          // 32px hero numbers
    static let textBright    = Color(red: 0xF0/255, green: 0xF4/255, blue: 0xFC/255)  // titles, 15:1
    static let textPrimary   = Color(red: 0xC8/255, green: 0xCE/255, blue: 0xDA/255)  // body, 10:1
    static let textSecondary = Color(red: 0x8B/255, green: 0x94/255, blue: 0x9E/255)  // labels, 6:1
    static let textMuted     = Color(red: 0x6B/255, green: 0x73/255, blue: 0x86/255)  // dim, 4.5:1
    static let textDim       = Color(red: 0x58/255, green: 0x60/255, blue: 0x7A/255)  // very dim, 3.5:1

    // MARK: - Semantic accent colors (strict meaning)

    static let cyan    = Color(red: 0x22/255, green: 0xD3/255, blue: 0xEE/255)  // Interactive/active/links
    static let violet  = Color(red: 0xA7/255, green: 0x8B/255, blue: 0xFA/255)  // AI/Claude identity
    static let emerald = Color(red: 0x34/255, green: 0xD3/255, blue: 0x99/255)  // Success/healthy/+lines
    static let rose    = Color(red: 0xFB/255, green: 0x71/255, blue: 0x85/255)  // Error/dead/-lines
    static let amber   = Color(red: 0xFB/255, green: 0xBF/255, blue: 0x24/255)  // Warning/attention/cost

    // MARK: - Borders and depth

    static let border       = Color.white.opacity(0.10)    // visible card edges
    static let borderSubtle = Color.white.opacity(0.06)    // secondary separators

    /// Card shadow — use instead of hairline borders for depth
    static func cardShadow() -> some ViewModifier { CardShadow() }

    // MARK: - Spacing (strict 4px grid)

    enum Sp {
        static let xs:  CGFloat = 4
        static let sm:  CGFloat = 8
        static let md:  CGFloat = 12
        static let lg:  CGFloat = 16
        static let xl:  CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // MARK: - Typography

    /// Hero display number (32px, bold, system font — NOT monospace)
    static func heroFont() -> Font { .system(size: 32, weight: .bold) }
    /// Section title (13px, bold, monospaced, tracked)
    static func sectionFont() -> Font { .system(size: 13, weight: .bold, design: .monospaced) }
    /// Card title (14px, semibold, monospaced)
    static func titleFont() -> Font { .system(size: 14, weight: .semibold, design: .monospaced) }
    /// Body data (12px, medium, monospaced)
    static func bodyFont() -> Font { .system(size: 12, weight: .medium, design: .monospaced) }
    /// Secondary label (11px, regular, monospaced)
    static func labelFont() -> Font { .system(size: 11, design: .monospaced) }
    /// Dim metadata (10px, regular, monospaced)
    static func metaFont() -> Font { .system(size: 10, design: .monospaced) }
    /// Tiny (9px)
    static func tinyFont() -> Font { .system(size: 9, design: .monospaced) }

    // MARK: - Background

    /// Dashboard background with subtle radial glow (replaces grid pattern)
    static func background() -> some View {
        ZStack {
            bgBase
            RadialGradient(
                colors: [cyan.opacity(0.025), Color.clear],
                center: .top, startRadius: 0, endRadius: 600
            )
        }
    }

    // MARK: - Relative Time

    static func relativeTime(_ date: Date?) -> String {
        guard let date else { return "" }
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "now" }
        if interval < 3600 {
            let mins = Int(interval / 60)
            return "\(mins)m ago"
        }
        if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)h ago"
        }
        if interval < 172800 { return "Yesterday" }
        let formatter = DateFormatter()
        if interval < 604800 {
            formatter.dateFormat = "EEEE"  // "Wednesday"
        } else {
            formatter.dateFormat = "MMM d"  // "Mar 15"
        }
        return formatter.string(from: date)
    }

    // MARK: - Cost Formatting

    static func formatCost(_ cost: Double) -> String {
        if cost <= 0 { return "$0" }
        if cost < 0.01 { return "<$0.01" }
        if cost < 10 { return String(format: "$%.2f", cost) }
        if cost < 100 { return String(format: "$%.1f", cost) }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencySymbol = "$"
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: cost)) ?? String(format: "$%.0f", cost)
    }

    static func formatTokens(_ tokens: Int) -> String {
        if tokens < 1000 { return "\(tokens)" }
        if tokens < 1_000_000 { return String(format: "%.1fk", Double(tokens) / 1000) }
        return String(format: "%.1fM", Double(tokens) / 1_000_000)
    }

    // MARK: - Outcome Colors

    static func outcomeColor(_ outcome: String?) -> Color {
        guard let o = outcome?.lowercased() else { return textDim }
        if o.contains("fully") || o.contains("success") { return emerald }
        if o.contains("mostly") || o.contains("partial") { return amber }
        if o.contains("fail") || o.contains("abandon") || o.contains("not_achieved") { return rose }
        return textMuted
    }

    // MARK: - Group Colors (from existing sidebar)

    static let groupColors: [(String, Color)] = [
        ("blue", cyan), ("green", emerald),
        ("purple", violet), ("orange", amber),
        ("red", rose), ("pink", Color(red: 0xDB/255, green: 0x61/255, blue: 0xA2/255)),
    ]
    static func groupColor(_ name: String) -> Color {
        groupColors.first(where: { $0.0 == name })?.1 ?? cyan
    }

    /// Cycling colors for project bars (5 distinct colors)
    static let projectColors: [Color] = [cyan, emerald, violet, amber, rose]
    static func projectColor(_ index: Int) -> Color {
        projectColors[index % projectColors.count]
    }
}

// MARK: - Card Shadow Modifier

private struct CardShadow: ViewModifier {
    func body(content: Content) -> some View {
        content
            .shadow(color: Color.black.opacity(0.25), radius: 8, x: 0, y: 2)
            .shadow(color: Color.black.opacity(0.1), radius: 2, x: 0, y: 1)
    }
}

extension View {
    func mcCardShadow() -> some View { modifier(MC.cardShadow()) }
}

// MARK: - Toast System

class ToastManager: ObservableObject {
    @Published var message: String? = nil
    private var dismissTask: DispatchWorkItem?

    func show(_ text: String, duration: TimeInterval = 2.0) {
        dismissTask?.cancel()
        withAnimation(.easeInOut(duration: 0.15)) { message = text }
        let task = DispatchWorkItem { [weak self] in
            withAnimation(.easeInOut(duration: 0.2)) { self?.message = nil }
        }
        dismissTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: task)
    }
}

struct ToastOverlay: View {
    @ObservedObject var manager: ToastManager

    var body: some View {
        if let msg = manager.message {
            VStack {
                Spacer()
                Text(msg)
                    .font(MC.bodyFont())
                    .foregroundColor(MC.textBright)
                    .padding(.horizontal, MC.Sp.lg)
                    .padding(.vertical, MC.Sp.sm)
                    .background(MC.bgElevated)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .mcCardShadow()
                    .padding(.bottom, MC.Sp.xl)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

// MARK: - Skeleton Loader

struct SkeletonCard: View {
    @State private var shimmerOffset: CGFloat = -1.0

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(MC.bgSurface)
            .frame(height: 80)
            .overlay(
                GeometryReader { geo in
                    LinearGradient(
                        colors: [Color.clear, Color.white.opacity(0.03), Color.clear],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 0.5)
                    .offset(x: shimmerOffset * geo.size.width)
                }
                .clipped()
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onAppear {
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    shimmerOffset = 2.0
                }
            }
    }
}

struct SkeletonLoadingView: View {
    var body: some View {
        VStack(spacing: MC.Sp.sm) {
            ForEach(0..<5, id: \.self) { _ in
                SkeletonCard()
            }
        }
        .padding(MC.Sp.lg)
    }
}

// MARK: - Interactive Chart Tooltip

struct ChartTooltip: View {
    let title: String
    let value: String
    let subtitle: String?

    init(_ title: String, value: String, subtitle: String? = nil) {
        self.title = title; self.value = value; self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(MC.metaFont()).foregroundColor(MC.textMuted)
            Text(value).font(MC.bodyFont()).foregroundColor(MC.textBright)
            if let sub = subtitle {
                Text(sub).font(MC.tinyFont()).foregroundColor(MC.textDim)
            }
        }
        .padding(.horizontal, MC.Sp.sm)
        .padding(.vertical, MC.Sp.xs)
        .background(MC.bgElevated)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .mcCardShadow()
    }
}

// MARK: - Context Fill Bar

struct ContextFillBar: View {
    let fillPercent: Double  // 0-100

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(MC.bgBase)
                RoundedRectangle(cornerRadius: 2)
                    .fill(fillColor)
                    .frame(width: geo.size.width * CGFloat(min(fillPercent, 100)) / 100)
            }
        }
        .frame(height: 4)
    }

    private var fillColor: Color {
        if fillPercent > 90 { return MC.rose }
        if fillPercent > 70 { return MC.amber }
        return MC.cyan.opacity(0.6)
    }
}
