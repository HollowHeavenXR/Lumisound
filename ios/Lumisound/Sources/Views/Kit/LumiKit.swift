import SwiftUI

// MARK: - LumiKit
//
// The building blocks of the redesigned Settings family (Settings, Profile,
// Subscriptions and every screen reachable from Settings). One visual
// language — floating cards on the gallery background, a tinted icon badge
// per row, a hero header per page — so dozens of screens read as one app,
// while each screen still gets its own layout. Everything takes colours from
// `AppTheme`, so the kit follows the active interface edition, the accent
// colour and Liquid Glass automatically.

enum LK {
    static let corner: CGFloat = 20
    static let rowCorner: CGFloat = 14
    static let gutter: CGFloat = 16
    static let spacing: CGFloat = 14
}

// MARK: Page

/// A scrolling page: optional hero header, then content cards.
struct LKPage<Content: View>: View {
    var title: String
    var subtitle: String? = nil
    var icon: String? = nil
    var tint: Color = AppTheme.dynamicAccent
    var showsHero = true
    var showsMiniPlayer = true
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: LK.spacing) {
                if showsHero, let icon {
                    LKHero(title: title, subtitle: subtitle, icon: icon, tint: tint)
                        .padding(.bottom, 2)
                }
                content()
            }
            .padding(.horizontal, LK.gutter)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(GalleryBackgroundView().ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            if showsMiniPlayer { MiniPlayerBar() }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Big tinted badge, title and one-line story for a page.
struct LKHero: View {
    let title: String
    var subtitle: String?
    let icon: String
    var tint: Color

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .background(
                    LinearGradient(colors: [tint, tint.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .shadow(color: tint.opacity(0.4), radius: 10, x: 0, y: 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 6)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Cards

/// A floating card with an optional small-caps title and footer.
struct LKCard<Content: View>: View {
    var title: String? = nil
    var footer: String? = nil
    var padding: CGFloat = 14
    /// Space between rows (0 for rows that bring their own padding).
    var spacing: CGFloat = 0
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                LKSectionTitle(title)
            }
            VStack(alignment: .leading, spacing: spacing) {
                content()
            }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LKCardBackground())
            if let footer {
                Text(footer)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6)
            }
        }
    }
}

struct LKCardBackground: View {
    var tint: Color? = nil
    var corner: CGFloat = LK.corner

    var body: some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(AppTheme.surface)
            .overlay {
                if let tint {
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .fill(LinearGradient(colors: [tint.opacity(0.18), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
                }
            }
            .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(AppTheme.textPrimary.opacity(0.06), lineWidth: 1))
    }
}

struct LKSectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .bold))
            .kerning(1.1)
            .foregroundStyle(AppTheme.textSecondary)
            .padding(.horizontal, 6)
            .accessibilityAddTraits(.isHeader)
    }
}

struct LKDivider: View {
    var inset: CGFloat = 44
    var body: some View {
        Rectangle()
            .fill(AppTheme.textSecondary.opacity(0.14))
            .frame(height: 0.5)
            .padding(.leading, inset)
    }
}

// MARK: Rows

/// Tinted rounded-square icon badge.
struct LKIcon: View {
    let symbol: String
    var tint: Color = AppTheme.dynamicAccent
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.47, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Icon, title, optional subtitle, optional trailing value and chevron.
struct LKRow: View {
    let icon: String
    var tint: Color = AppTheme.dynamicAccent
    let title: String
    var subtitle: String? = nil
    var value: String? = nil
    var valueTint: Color? = nil
    var chevron = true
    var destructive = false

    var body: some View {
        HStack(spacing: 12) {
            LKIcon(symbol: icon, tint: destructive ? AppTheme.error : tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppTheme.bodyFont(size: 15))
                    .foregroundStyle(destructive ? AppTheme.error : AppTheme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if let value {
                Text(value)
                    .font(AppTheme.bodyFont(size: 13))
                    .foregroundStyle(valueTint ?? AppTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary.opacity(0.55))
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

/// A navigation row.
struct LKLink<Destination: View>: View {
    let icon: String
    var tint: Color = AppTheme.dynamicAccent
    let title: String
    var subtitle: String? = nil
    var value: String? = nil
    var valueTint: Color? = nil
    @ViewBuilder var destination: () -> Destination

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            LKRow(icon: icon, tint: tint, title: title, subtitle: subtitle, value: value, valueTint: valueTint)
        }
        .buttonStyle(.plain)
    }
}

/// An action row (no chevron unless asked).
struct LKButtonRow: View {
    let icon: String
    var tint: Color = AppTheme.dynamicAccent
    let title: String
    var subtitle: String? = nil
    var destructive = false
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                LKRow(icon: icon, tint: tint, title: title, subtitle: subtitle, chevron: false, destructive: destructive)
                if busy { ProgressView().tint(tint) }
            }
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }
}

/// A switch row.
struct LKToggle: View {
    let icon: String
    var tint: Color = AppTheme.dynamicAccent
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 12) {
                LKIcon(symbol: icon, tint: tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(AppTheme.bodyFont(size: 15))
                        .foregroundStyle(AppTheme.textPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(AppTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .tint(tint)
        .padding(.vertical, 6)
    }
}

/// Title + live value over a full-width control (slider, stepper…).
struct LKControlRow<Control: View>: View {
    let icon: String
    var tint: Color = AppTheme.dynamicAccent
    let title: String
    var value: String? = nil
    @ViewBuilder var control: () -> Control

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                LKIcon(symbol: icon, tint: tint)
                Text(title)
                    .font(AppTheme.bodyFont(size: 15))
                    .foregroundStyle(AppTheme.textPrimary)
                Spacer()
                if let value {
                    Text(value)
                        .font(AppTheme.monoFont(size: 13))
                        .foregroundStyle(tint)
                }
            }
            control()
                .tint(tint)
                .padding(.leading, 42)
        }
        .padding(.vertical, 8)
    }
}

/// Explanatory text inside a card, indented under the icon column.
struct LKNote: View {
    let text: String
    var inset: CGFloat = 42
    init(_ text: String, inset: CGFloat = 42) {
        self.text = text
        self.inset = inset
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(AppTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, inset)
            .padding(.bottom, 6)
    }
}

// MARK: Tiles, chips, stats

/// A square-ish tile for grids of destinations.
struct LKTile: View {
    let icon: String
    var tint: Color = AppTheme.dynamicAccent
    let title: String
    var detail: String? = nil
    var badge: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                LKIcon(symbol: icon, tint: tint, size: 34)
                Spacer()
                if let badge {
                    Text(badge)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(tint, in: Capsule())
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .background(LKCardBackground(tint: tint, corner: 18))
        .contentShape(Rectangle())
    }
}

struct LKTileLink<Destination: View>: View {
    let icon: String
    var tint: Color = AppTheme.dynamicAccent
    let title: String
    var detail: String? = nil
    var badge: String? = nil
    @ViewBuilder var destination: () -> Destination

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            LKTile(icon: icon, tint: tint, title: title, detail: detail, badge: badge)
        }
        .buttonStyle(.plain)
    }
}

/// Two-column grid.
struct LKGrid<Content: View>: View {
    var columns = 2
    @ViewBuilder var content: () -> Content

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columns), spacing: 12) {
            content()
        }
    }
}

struct LKStat: View {
    let value: String
    let label: String
    var icon: String? = nil
    var tint: Color = AppTheme.dynamicAccent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(tint)
            }
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.caption2)
                .foregroundStyle(AppTheme.textSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(LKCardBackground(tint: tint, corner: 16))
        .accessibilityElement(children: .combine)
    }
}

struct LKChip: View {
    let title: String
    var icon: String? = nil
    var selected = false
    var tint: Color = AppTheme.dynamicAccent

    var body: some View {
        HStack(spacing: 5) {
            if let icon { Image(systemName: icon).font(.caption2.weight(.bold)) }
            Text(title).font(.caption.weight(.semibold)).lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .foregroundStyle(selected ? .white : AppTheme.textPrimary)
        .background(selected ? AnyShapeStyle(tint) : AnyShapeStyle(AppTheme.elevatedSurface), in: Capsule())
    }
}

/// Status pill ("On", "Needs access"…).
struct LKPill: View {
    let text: String
    var tint: Color = AppTheme.dynamicAccent

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.15), in: Capsule())
    }
}

/// A segmented chooser with the kit's look (chips in a capsule track).
struct LKSegmented<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    var tint: Color = AppTheme.dynamicAccent

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options.indices, id: \.self) { i in
                let (value, label) = options[i]
                let on = value == selection
                Button {
                    UISelectionFeedbackGenerator().selectionChanged()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { selection = value }
                } label: {
                    Text(label)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .foregroundStyle(on ? .white : AppTheme.textSecondary)
                        .background {
                            if on { Capsule().fill(tint) }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(4)
        .background(AppTheme.elevatedSurface, in: Capsule())
    }
}

/// Big primary / secondary buttons.
struct LKPrimaryButton: View {
    let title: String
    var icon: String? = nil
    var tint: Color = AppTheme.dynamicAccent
    var prominent = true
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if busy {
                    ProgressView().tint(prominent ? .white : tint)
                } else if let icon {
                    Image(systemName: icon)
                }
                Text(title).lineLimit(1)
            }
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .foregroundStyle(prominent ? .white : tint)
            .background(prominent ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(tint.opacity(0.14)),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }
}

/// Empty / all-clear state.
struct LKEmpty: View {
    let icon: String
    let title: String
    var message: String? = nil
    var tint: Color = AppTheme.dynamicAccent

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(AppTheme.headlineFont(size: 16))
                .foregroundStyle(AppTheme.textPrimary)
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .background(LKCardBackground())
    }
}

/// A styled text field inside cards.
struct LKField: View {
    let placeholder: String
    @Binding var text: String
    var secure = false
    var mono = false

    var body: some View {
        Group {
            if secure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .font(mono ? AppTheme.monoFont(size: 14) : AppTheme.bodyFont(size: 15))
        .foregroundStyle(AppTheme.textPrimary)
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .padding(12)
        .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// A callout banner (info / warning / success).
struct LKBanner: View {
    let icon: String
    let text: String
    var tint: Color = AppTheme.dynamicAccent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
            Text(text)
                .font(.caption)
                .foregroundStyle(AppTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(tint.opacity(0.25), lineWidth: 1))
    }
}

// MARK: - LKSection

/// A card that takes the same shapes as SwiftUI's `Section` (`content`,
/// optional `header`, optional `footer`, or a title string), so list screens
/// move onto the kit without rewriting every section.
struct LKSection<Content: View, Header: View, Footer: View>: View {
    private let content: Content
    private let header: Header
    private let footer: Footer
    private let hasHeader: Bool
    private let hasFooter: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if hasHeader {
                header
                    .font(.system(size: 11, weight: .bold))
                    .textCase(.uppercase)
                    .kerning(1.0)
                    .foregroundStyle(AppTheme.textSecondary)
                    .padding(.horizontal, 6)
            }
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LKCardBackground())
            if hasFooter {
                footer
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6)
            }
        }
    }
}

extension LKSection where Header == EmptyView, Footer == EmptyView {
    init(@ViewBuilder content: () -> Content) {
        self.content = content(); header = EmptyView(); footer = EmptyView(); hasHeader = false; hasFooter = false
    }
}

extension LKSection where Header == Text, Footer == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.content = content(); header = Text(title); footer = EmptyView(); hasHeader = true; hasFooter = false
    }
}

extension LKSection where Footer == EmptyView {
    init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header) {
        self.content = content(); self.header = header(); footer = EmptyView(); hasHeader = true; hasFooter = false
    }
}

extension LKSection where Header == EmptyView {
    init(@ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.content = content(); header = EmptyView(); self.footer = footer(); hasHeader = false; hasFooter = true
    }
}

extension LKSection {
    init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header, @ViewBuilder footer: () -> Footer) {
        self.content = content(); self.header = header(); self.footer = footer(); hasHeader = true; hasFooter = true
    }
}

/// A bare kit scroll container (for sheets and secondary lists): padded lazy
/// stack on the gallery background, no hero, no title.
struct LKScroll<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: LK.spacing) {
                content()
            }
            .padding(.horizontal, LK.gutter)
            .padding(.vertical, 12)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(GalleryBackgroundView().ignoresSafeArea())
    }
}

/// For navigation rows inside kit cards: plain label, trailing chevron and a
/// pressed state (what a List row used to provide).
struct LKRowLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary.opacity(0.55))
        }
        .contentShape(Rectangle())
        .opacity(configuration.isPressed ? 0.55 : 1)
    }
}
