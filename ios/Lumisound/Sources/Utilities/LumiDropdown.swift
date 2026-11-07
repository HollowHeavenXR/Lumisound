import SwiftUI
import UIKit

// Lumisound's own dropdowns, replacing the system menu-style Pickers.
//
// All the behavior lives in the Rust `DropdownEngine` (rust/core/src/
// dropdown.rs): option state, search ranking + match ranges, highlight /
// type-ahead navigation, and where the panel goes (below the control when
// it fits, otherwise above, clamped to the screen, scrolled to the current
// choice). This file only draws what it computes.
//
// `LumiPicker` keeps `Picker`'s call shape: options are the content's
// subviews, their values come from `.tag(_:)`. Add `.lumiOptionLabel(_:)`
// to options to make long lists searchable.

extension ContainerValues {
    /// Searchable text for a `LumiPicker` option.
    @Entry var lumiOptionLabel: String? = nil
}

extension View {
    /// Searchable text for this option inside a `LumiPicker`.
    func lumiOptionLabel(_ label: String) -> some View {
        containerValue(\.lumiOptionLabel, label)
    }
}

// MARK: - Picker

struct LumiPicker<SelectionValue: Hashable, Content: View, Label: View>: View {
    @Binding private var selection: SelectionValue
    private let content: Content
    private let label: Label
    /// Show `label` alone as the control (sort buttons and the like).
    private var bare = false
    @State private var engine = DropdownEngine()
    @State private var frame: CGRect = .zero
    @Environment(\.isEnabled) private var isEnabled

    init(selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
        _selection = selection
        self.content = content()
        self.label = label()
    }

    /// A dropdown opened by `trigger` drawn as-is (no title/value/chevron),
    /// for icon buttons such as "Sort".
    init(selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content, @ViewBuilder trigger: () -> Label) {
        self.init(selection: selection, content: content, label: trigger)
        bare = true
    }

    private struct Opt {
        let id: String
        let tag: SelectionValue
        let label: String?
        let view: Subview
    }

    var body: some View {
        Group(subviews: content) { subviews in
            let opts = Self.options(subviews)
            let current = opts.first { $0.tag == selection }
            Button {
                open(opts)
            } label: {
                if bare {
                    label.contentShape(Rectangle())
                } else {
                    closedControl(current)
                }
            }
            .buttonStyle(.plain)
            .opacity(isEnabled ? 1 : 0.5)
            .accessibilityValue(current?.label ?? "")
            .accessibilityHint("Opens a list of choices")
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
        }
    }

    private func closedControl(_ current: Opt?) -> some View {
                HStack(spacing: 8) {
                    label
                        .foregroundStyle(AppTheme.textPrimary)
                    Spacer(minLength: 8)
                    if let current {
                        current.view
                            .lineLimit(1)
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .contentShape(Rectangle())
    }

    private static func options(_ subviews: SubviewsCollection) -> [Opt] {
        var out: [Opt] = []
        for (i, sv) in subviews.enumerated() {
            guard let tag = sv.containerValues.tag(for: SelectionValue.self) else { continue }
            out.append(Opt(id: String(i), tag: tag, label: sv.containerValues.lumiOptionLabel, view: sv))
        }
        return out
    }

    private func open(_ opts: [Opt]) {
        guard isEnabled, !opts.isEmpty else { return }
        engine.setOptions(options: opts.map {
            DropdownOption(id: $0.id, label: $0.label ?? "", detail: nil, enabled: true)
        })
        engine.setSearchable(searchable: opts.allSatisfy { $0.label != nil })
        engine.setSelected(id: opts.first { $0.tag == selection }?.id)
        let binding = $selection
        let items = Dictionary(uniqueKeysWithValues: opts.map {
            ($0.id, LumiDropdownPresenter.Item(view: AnyView($0.view), label: $0.label))
        })
        let tags = Dictionary(uniqueKeysWithValues: opts.map { ($0.id, $0.tag) })
        LumiDropdownPresenter.shared.present(engine: engine, items: items, anchor: frame) { id in
            if let tag = tags[id] { binding.wrappedValue = tag }
        }
    }
}

extension LumiPicker where Label == Text {
    init<S: StringProtocol>(_ title: S, selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content) {
        self.init(selection: selection, content: content) { Text(title) }
    }

    init(_ titleKey: LocalizedStringKey, selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content) {
        self.init(selection: selection, content: content) { Text(titleKey) }
    }
}

// MARK: - Presenter

/// Shows one dropdown at a time in its own window above everything, so it
/// works the same inside sheets, popovers and full-screen covers.
@MainActor
final class LumiDropdownPresenter: ObservableObject {
    static let shared = LumiDropdownPresenter()

    struct Item {
        let view: AnyView
        let label: String?
    }

    static let rowHeight: CGFloat = 44
    static let maxRows: UInt32 = 7
    static let minWidth: CGFloat = 220

    @Published private(set) var isPresented = false
    @Published private(set) var rows: [DropdownRow] = []
    @Published private(set) var layout: DropdownLayout?
    @Published private(set) var query = ""
    private(set) var items: [String: Item] = [:]

    private var engine: DropdownEngine?
    private var onChoose: ((String) -> Void)?
    private var anchor: CGRect = .zero
    private var window: UIWindow?
    private weak var previousKey: UIWindow?
    private var generation = 0

    private init() {
        NotificationCenter.default.addObserver(forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LumiDropdownPresenter.shared.dismiss() }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LumiDropdownPresenter.shared.dismiss() }
        }
    }

    func present(engine: DropdownEngine, items: [String: Item], anchor: CGRect, onChoose: @escaping (String) -> Void) {
        if isPresented { dismiss() }
        guard let window = ensureWindow() else { return }
        engine.open()
        self.engine = engine
        self.items = items
        self.anchor = anchor
        self.onChoose = onChoose
        query = ""
        generation += 1
        rows = engine.rows()
        layout = computeLayout(in: window)
        window.isHidden = false
        UISelectionFeedbackGenerator().selectionChanged()
        isPresented = true
    }

    func setQuery(_ q: String) {
        guard q != query, let engine else { return }
        query = q
        engine.setQuery(query: q)
        rows = engine.rows()
        if let window { layout = computeLayout(in: window) }
    }

    /// Keyboard search field became active: the window must be key.
    func searchFocused() {
        guard let window, !window.isKeyWindow else { return }
        previousKey = window.windowScene?.keyWindow
        window.makeKey()
    }

    func choose(_ id: String?) {
        guard let engine else { return }
        if let changed = engine.choose(id: id) {
            UISelectionFeedbackGenerator().selectionChanged()
            onChoose?(changed)
        }
        dismiss()
    }

    func dismiss() {
        guard isPresented else { return }
        engine?.close()
        isPresented = false
        onChoose = nil
        let gen = generation
        if window?.isKeyWindow == true { previousKey?.makeKey() }
        // Hide after the close animation (a hidden window also hands the
        // status bar and touches back to the app).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.generation == gen, !self.isPresented else { return }
            self.window?.isHidden = true
            self.items = [:]
            self.engine = nil
        }
    }

    private func computeLayout(in window: UIWindow) -> DropdownLayout? {
        guard let engine else { return nil }
        let b = window.bounds
        let insets = window.safeAreaInsets
        return engine.layout(
            anchor: DropRect(x: anchor.minX, y: anchor.minY, width: anchor.width, height: anchor.height),
            viewport: DropRect(x: b.minX, y: b.minY, width: b.width, height: b.height),
            insetTop: insets.top, insetBottom: insets.bottom,
            rowHeight: Self.rowHeight, maxRows: Self.maxRows, minWidth: Self.minWidth
        )
    }

    private func ensureWindow() -> UIWindow? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard let scene else { return nil }
        if let window, window.windowScene === scene { return window }
        let w = UIWindow(windowScene: scene)
        w.windowLevel = .alert + 1
        w.backgroundColor = .clear
        let host = UIHostingController(rootView: LumiDropdownOverlay())
        host.view.backgroundColor = .clear
        w.rootViewController = host
        w.isHidden = true
        window = w
        return w
    }
}

// MARK: - Panel

private struct LumiDropdownOverlay: View {
    @ObservedObject private var p = LumiDropdownPresenter.shared

    var body: some View {
        ZStack(alignment: .topLeading) {
            if p.isPresented, let l = p.layout {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { p.dismiss() }
                    .accessibilityLabel("Close list")
                    .accessibilityAddTraits(.isButton)
                LumiDropdownPanel(layout: l)
                    .frame(width: l.frame.width, height: l.frame.height)
                    .offset(x: l.frame.x, y: l.frame.y)
                    .transition(.scale(scale: 0.94, anchor: l.opensUp ? .bottom : .top).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        .animation(.spring(response: 0.26, dampingFraction: 0.88), value: p.isPresented)
    }
}

private struct LumiDropdownPanel: View {
    let layout: DropdownLayout
    @ObservedObject private var p = LumiDropdownPresenter.shared
    @FocusState private var searchFocused: Bool

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 14, style: .continuous) }

    var body: some View {
        VStack(spacing: 0) {
            if layout.showSearch { searchField }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(p.rows, id: \.id) { row in
                            rowView(row).id(row.id)
                        }
                        if p.rows.isEmpty {
                            Text("No matches")
                                .font(.subheadline)
                                .foregroundStyle(AppTheme.textSecondary)
                                .frame(height: LumiDropdownPresenter.rowHeight)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.automatic)
                .onAppear {
                    if let s = layout.scrollTo, Int(s) < p.rows.count {
                        proxy.scrollTo(p.rows[Int(s)].id, anchor: .center)
                    }
                }
            }
        }
        .background(.ultraThinMaterial, in: shape)
        .background(AppTheme.elevatedSurface.opacity(0.55), in: shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
        .clipShape(shape)
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(AppTheme.textSecondary)
            TextField("Search", text: Binding(get: { p.query }, set: { p.setQuery($0) }))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($searchFocused)
                .onSubmit { p.choose(nil) }
                .foregroundStyle(AppTheme.textPrimary)
        }
        .padding(.horizontal, 12)
        .frame(height: LumiDropdownPresenter.rowHeight)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 6)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .onChange(of: searchFocused) { _, focused in if focused { p.searchFocused() } }
    }

    @ViewBuilder
    private func rowView(_ row: DropdownRow) -> some View {
        let item = p.items[row.id]
        Button {
            p.choose(row.id)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "checkmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(AppTheme.dynamicAccent)
                    .opacity(row.selected ? 1 : 0)
                    .frame(width: 16)
                Group {
                    if !p.query.isEmpty, let label = item?.label {
                        Text(highlighted(label, row.matches))
                    } else if let view = item?.view {
                        view
                    } else {
                        Text(row.label)
                    }
                }
                .lineLimit(1)
                .foregroundStyle(row.enabled ? AppTheme.textPrimary : AppTheme.textSecondary.opacity(0.5))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: LumiDropdownPresenter.rowHeight)
            .background(row.highlighted && !p.query.isEmpty ? AppTheme.dynamicAccent.opacity(0.16) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(LumiDropdownRowStyle())
        .disabled(!row.enabled)
        .accessibilityAddTraits(row.selected ? .isSelected : [])
    }

    private func highlighted(_ label: String, _ ranges: [MatchRange]) -> AttributedString {
        var s = AttributedString(label)
        let count = s.characters.count
        for r in ranges where r.start < r.end && Int(r.end) <= count {
            let a = s.characters.index(s.startIndex, offsetBy: Int(r.start))
            let b = s.characters.index(s.startIndex, offsetBy: Int(r.end))
            s[a..<b].foregroundColor = AppTheme.dynamicAccent
            s[a..<b].font = .body.weight(.semibold)
        }
        return s
    }
}

private struct LumiDropdownRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.white.opacity(0.08) : .clear)
    }
}
