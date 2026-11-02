import SwiftUI
import Charts
import ModelDeckCore

enum DeckTheme {
    static func adaptive(_ dark: NSColor, _ light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
    static let mint = adaptive(.init(red: 0.40, green: 0.88, blue: 0.72, alpha: 1), .init(red: 0.08, green: 0.45, blue: 0.34, alpha: 1))
    static let blue = adaptive(.init(red: 0.46, green: 0.68, blue: 0.99, alpha: 1), .init(red: 0.16, green: 0.36, blue: 0.74, alpha: 1))
    static let purple = adaptive(.init(red: 0.70, green: 0.57, blue: 0.96, alpha: 1), .init(red: 0.47, green: 0.30, blue: 0.74, alpha: 1))
    static let amber = adaptive(.init(red: 0.96, green: 0.72, blue: 0.38, alpha: 1), .init(red: 0.62, green: 0.37, blue: 0.06, alpha: 1))
    static func hex(_ value: UInt32) -> NSColor { NSColor(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1) }
    // Button tokens: neutral fill, mint edge only on the primary button. Contrast of each text on its fill is above 4.5:1.
    static let buttonFill = adaptive(hex(0x262d32), hex(0xe9edf0))
    static let buttonTextPrimary = adaptive(hex(0xf0f4f6), hex(0x0e1216))
    static let buttonTextOther = adaptive(hex(0xc3ccd1), hex(0x3a454c))
    static let background = adaptive(.init(red: 0.055, green: 0.071, blue: 0.085, alpha: 1), .init(red: 0.95, green: 0.96, blue: 0.97, alpha: 1))
    static let card = adaptive(.init(red: 0.085, green: 0.105, blue: 0.121, alpha: 1), .white)
    static let muted = Color(nsColor: .secondaryLabelColor)
    static let foreground = Color(nsColor: .labelColor)
    static let subtle = adaptive(.white, .black)
    static func usage(_ value: Double) -> Color { value >= 90 ? .red : value >= 70 ? amber : mint }
}

/// Neutral button with a mint edge on the primary one; replaces the white-on-green prominent style.
struct DeckButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12).padding(.vertical, 5)
            .foregroundStyle(primary ? DeckTheme.buttonTextPrimary : DeckTheme.buttonTextOther)
            .background(DeckTheme.buttonFill, in: RoundedRectangle(cornerRadius: 6))
            .overlay { if primary { RoundedRectangle(cornerRadius: 6).strokeBorder(DeckTheme.mint, lineWidth: 1.5) } }
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Tab button: the selected tab gets the neutral fill and the mint edge, the others stay plain.
struct DeckTabStyle: ButtonStyle {
    var selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 14).padding(.vertical, 6)
            .foregroundStyle(selected ? DeckTheme.buttonTextPrimary : DeckTheme.buttonTextOther)
            .background(selected ? DeckTheme.buttonFill : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay { if selected { RoundedRectangle(cornerRadius: 6).strokeBorder(DeckTheme.mint, lineWidth: 1.5) } }
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct DeckCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(DeckTheme.card, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(DeckTheme.subtle.opacity(0.065), lineWidth: 1))
    }
}

struct SectionLabel: View {
    let title: String
    var trailing: String? = nil
    var body: some View {
        HStack {
            Text(D(title)).font(.system(size: 11, weight: .semibold, design: .monospaced)).tracking(1.8)
            Spacer()
            if let trailing { Text(D(trailing)).font(.system(size: 11)).tracking(0) }
        }.foregroundStyle(DeckTheme.muted)
    }
}

struct StatusPill: View {
    let text: String
    var color = DeckTheme.mint
    var body: some View {
        HStack(spacing: 5) { Circle().fill(color).frame(width: 5, height: 5); Text(D(text)).font(.system(size: 10, weight: .medium)) }
            .foregroundStyle(color).padding(.horizontal, 8).padding(.vertical, 5)
            .background(color.opacity(0.10), in: Capsule())
    }
}

struct Sparkline: View {
    let values: [Double]
    let color: Color
    var body: some View {
        Chart(Array(values.enumerated()), id: \.offset) { item in
            AreaMark(x: .value("Campione", item.offset), y: .value("Percentuale", item.element))
                .foregroundStyle(LinearGradient(colors: [color.opacity(0.24), color.opacity(0.01)], startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.monotone)
            LineMark(x: .value("Campione", item.offset), y: .value("Percentuale", item.element)).foregroundStyle(color).lineStyle(.init(lineWidth: 1.6)).interpolationMethod(.monotone)
        }.chartXAxis(.hidden).chartYAxis(.hidden).chartYScale(domain: 0...100).frame(height: 48)
            .accessibilityLabel(L("Storico, ultimi \(values.count) campioni"))
    }
}

struct MetricCard: View {
    let title: String, symbol: String, value: String, detail: String
    let color: Color
    var history: [Double] = []
    var body: some View {
        DeckCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Image(systemName: symbol).foregroundStyle(color); Text(D(title)).foregroundStyle(DeckTheme.muted); Spacer() }.font(.system(size: 11, weight: .medium))
                Text(value).font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit().tracking(-1)
                Sparkline(values: history, color: color)
                Text(D(detail)).font(.system(size: 10)).foregroundStyle(DeckTheme.muted).lineLimit(2).frame(height: 26, alignment: .topLeading)
            }
        }
    }
}

struct UsageCard: View {
    @EnvironmentObject var store: DeckStore
    @State private var showClaudeHelp = false
    let usage: SubscriptionUsage
    var compact = false
    var body: some View {
        DeckCard {
            VStack(alignment: .leading, spacing: compact ? 12 : 18) {
                HStack(spacing: 10) {
                    Image(systemName: usage.provider == "Claude" ? "asterisk" : usage.provider == "Google" ? "sparkle" : "circle.hexagongrid")
                        .font(.system(size: 19, weight: .medium)).foregroundStyle(usage.provider == "Claude" ? DeckTheme.amber : usage.provider == "Google" ? DeckTheme.blue : DeckTheme.mint)
                        .frame(width: 34, height: 34).background(DeckTheme.subtle.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(D(usage.provider)).font(.system(size: 15, weight: .semibold))
                        Text(D(usage.provider == "Claude" ? "Claude Code" : usage.provider == "Google" ? "Antigravity" : "Codex" + (usage.plan.map { " · " + $0.capitalized } ?? "")))
                            .font(.system(size: 10)).foregroundStyle(DeckTheme.muted)
                    }
                    Spacer()
                    if !usage.windows.isEmpty {
                        if usage.provider == "Claude" {
                            Button { showClaudeHelp = true } label: { StatusPill(text: D(usage.needsRefresh ? "Da aggiornare" : "Collegato"), color: usage.needsRefresh ? DeckTheme.amber : DeckTheme.mint) }.buttonStyle(.plain).help(L("Come aggiornare le quote di Claude Code"))
                        } else { StatusPill(text: D(usage.needsRefresh ? "Da aggiornare" : "Collegato"), color: usage.needsRefresh ? DeckTheme.amber : DeckTheme.mint) }
                    }
                }
                if usage.windows.isEmpty {
                    Text(D(usage.message ?? "Quote non disponibili")).font(.system(size: 12)).foregroundStyle(DeckTheme.muted).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, minHeight: compact ? 30 : 87, alignment: .topLeading)
                } else {
                    ForEach(usage.windows) { window in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text(D(window.title)).font(.system(size: 11)).foregroundStyle(DeckTheme.muted)
                                Spacer()
                                Text(D(window.isExpired ? "Da aggiornare" : "\(DeckFormat.percent(window.usedPercent)) usato"))
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(window.isExpired ? DeckTheme.muted : DeckTheme.foreground)
                            }
                            GeometryReader { geo in
                                Capsule().fill(DeckTheme.subtle.opacity(0.07))
                                Capsule().fill(window.isExpired ? DeckTheme.muted : DeckTheme.usage(window.usedPercent)).frame(width: geo.size.width * min(100, max(0, window.usedPercent)) / 100)
                            }.frame(height: 5)
                            if let reset = window.resetsAt {
                                HStack(spacing: 3) {
                                    Text(D(window.isExpired ? "Reset passato · attendi nuovi dati" : "Reset"))
                                    if !window.isExpired { Text(reset, style: .relative) }
                                }.font(.system(size: 10)).foregroundStyle(DeckTheme.muted)
                                .help(D(reset.formatted(date: .complete, time: .shortened)))
                            }
                        }
                    }
                    if let message = usage.message { Text(D(message)).font(.system(size: 10)).foregroundStyle(DeckTheme.amber).fixedSize(horizontal: false, vertical: true) }
                }
                if !compact {
                    HStack(spacing: 4) {
                        Text(D(usage.source))
                        Spacer(minLength: 0)
                        if let date = usage.updatedAt { Text(date, style: .time).monospacedDigit() }
                    }.font(.system(size: 9)).foregroundStyle(DeckTheme.muted)
                }
                if usage.provider == "Claude" {
                    HStack {
                        Button { showClaudeHelp = true } label: { Label(L("Come aggiornare"), systemImage: "questionmark.circle") }
                        Spacer()
                        Button(L("Rileggi dati")) { if !store.demo { store.claude = ClaudeUsage.read() }; showClaudeHelp = true }
                    }.font(.system(size: 10)).buttonStyle(DeckButtonStyle())
                }
            }
        }.frame(maxHeight: .infinity, alignment: .top)
            .sheet(isPresented: $showClaudeHelp) { ClaudeRefreshView().environmentObject(store) }
    }
}
