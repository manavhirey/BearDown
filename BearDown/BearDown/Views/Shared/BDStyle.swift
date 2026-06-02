import SwiftUI

/// Centralized tokens for BearDown's editorial-athletic UI system.
/// Keep redesigns consistent by composing these primitives instead of
/// re-deriving fonts/spacings/colors inline per-view.
public enum BDStyle {

    // MARK: – Fonts

    /// Hero title — serif, large, allowed to wrap.
    public static let displayTitle: Font = .system(.largeTitle, design: .serif).weight(.bold)
    /// Smaller serif display for inner page heroes.
    public static let displayMedium: Font = .system(.title2, design: .serif).weight(.bold)
    /// Editorial body in serif (summaries, notes, narrative copy).
    public static let bodySerif: Font = .system(.body, design: .serif)
    /// Default body, used for stats and structural copy.
    public static let bodyMono: Font = .system(.body, design: .monospaced)
    /// Tiny mono caps — used for eyebrow lines and pill labels.
    public static let monoTiny: Font = .system(.caption2, design: .monospaced).weight(.bold)
    /// Small mono caps — used for date strips and section labels.
    public static let monoSmall: Font = .system(.caption, design: .monospaced).weight(.bold)
    /// Heavy uppercase subhead — for section headers.
    public static let sectionHead: Font = .system(.subheadline).weight(.heavy)

    // MARK: – Tracking

    public static let trackingTight: CGFloat = 1.2
    public static let trackingWide: CGFloat = 1.4
    public static let trackingHero: CGFloat = 2.0

    // MARK: – Spacing

    public static let sectionSpacing: CGFloat = 32
    public static let groupSpacing: CGFloat = 16
    public static let itemSpacing: CGFloat = 10

    // MARK: – Visual

    public static let hairline: Color = .primary.opacity(0.12)
    public static let mutedText: Color = .primary.opacity(0.82)
    public static let chipBackground: Color = .primary.opacity(0.05)
    public static let cardCorner: CGFloat = 16
}

/// 1pt full-width hairline rule.
public struct BDHairline: View {
    public init() {}
    public var body: some View {
        Rectangle().fill(BDStyle.hairline).frame(height: 1)
    }
}

/// Mono-caps eyebrow ("MON · JUN 1 · 2026") rendered above headlines.
public struct BDEyebrow: View {
    private let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text.uppercased())
            .font(BDStyle.monoSmall)
            .tracking(BDStyle.trackingHero)
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Inline mono-caps label (form rows, table gutters).
public struct BDLabel: View {
    private let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text.uppercased())
            .font(BDStyle.monoTiny)
            .tracking(BDStyle.trackingWide)
            .foregroundStyle(.secondary)
    }
}

/// Status pill — tinted capsule with outline + icon.
public struct BDStatusPill: View {
    public let label: String
    public let systemImage: String
    public let color: Color
    public init(label: String, systemImage: String, color: Color) {
        self.label = label
        self.systemImage = systemImage
        self.color = color
    }
    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).font(.caption2.weight(.bold))
            Text(label.uppercased())
                .font(BDStyle.monoTiny)
                .tracking(BDStyle.trackingWide)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .foregroundStyle(color)
        .background(color.opacity(0.12), in: Capsule())
        .overlay(Capsule().stroke(color.opacity(0.3), lineWidth: 1))
    }
}

/// Kind chip (emoji + mono caps name).
public struct BDKindChip: View {
    public let emoji: String
    public let label: String
    public init(emoji: String, label: String) {
        self.emoji = emoji
        self.label = label
    }
    public var body: some View {
        HStack(spacing: 5) {
            Text(emoji).font(.caption)
            Text(label.uppercased())
                .font(BDStyle.monoTiny)
                .tracking(BDStyle.trackingTight)
                .foregroundStyle(.primary.opacity(0.65))
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(BDStyle.chipBackground, in: Capsule())
    }
}

/// Editorial section header: hairline rule above an uppercase title row.
public struct BDSectionHeader: View {
    public let leadingSymbol: String?
    public let title: String
    public let trailing: AnyView?
    public init(symbol: String? = nil, title: String, trailing: AnyView? = nil) {
        self.leadingSymbol = symbol
        self.title = title
        self.trailing = trailing
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            BDHairline()
            HStack(spacing: 10) {
                if let s = leadingSymbol { Text(s).font(.title3) }
                Text(title.uppercased())
                    .font(BDStyle.sectionHead)
                    .tracking(BDStyle.trackingTight)
                Spacer()
                if let trailing { trailing }
            }
        }
    }
}

/// Bordered, hollow editorial card — soft fill + 1pt outline.
public struct BDCard<Content: View>: View {
    public let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.gray.opacity(0.06), in: RoundedRectangle(cornerRadius: BDStyle.cardCorner))
            .overlay(RoundedRectangle(cornerRadius: BDStyle.cardCorner)
                .stroke(.primary.opacity(0.08), lineWidth: 1))
    }
}

/// Left-rule italic quote — used for notes/asides.
public struct BDQuote: View {
    public let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle()
                .fill(.primary.opacity(0.25))
                .frame(width: 2)
            Text(text)
                .font(.system(.footnote, design: .serif).italic())
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
