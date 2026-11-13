import SwiftUI

// MARK: - DuplicateFilesView

/// Duplicate Finder on the Lumisound Duplicate Engine: a scan summary, one
/// card per group (evidence, every copy with its strengths and warnings, a
/// keeper the listener can change), "Not duplicates", safe one-tap clean-up,
/// and a history where every clean-up can be undone.
struct DuplicateFilesView: View {

    @EnvironmentObject private var library: LibraryManager
    @StateObject private var service = DuplicateFinderService.shared

    @State private var filter: DupeKind?
    @State private var confirmGroup: DupeGroup?
    @State private var showCleanAllConfirm = false
    @State private var ignoredCount = dupeIgnoredCount()

    private var visibleGroups: [DupeGroup] {
        guard let filter else { return service.groups }
        return service.groups.filter { $0.kind == filter }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                summaryCard
                if !service.groups.isEmpty {
                    filterBar
                    ForEach(visibleGroups, id: \.id) { group in
                        DupeGroupCard(group: group) { keeper in
                            service.chooseKeeper(group, keeperID: keeper)
                        } onCleanUp: {
                            confirmGroup = group
                        } onIgnore: {
                            withAnimation(LumiMotion.fade(0.2)) { service.ignore(group) }
                            ignoredCount = dupeIgnoredCount()
                        }
                    }
                } else if !service.isScanning, service.lastScanDate != nil {
                    allClearCard
                }
                if !service.journal.isEmpty { historyCard }
                if ignoredCount > 0 { ignoredFooter }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .animation(LumiMotion.fade(0.22), value: service.groups.map(\.id))
        }
        .background(GalleryBackgroundView().ignoresSafeArea())
        .navigationTitle("Duplicate Finder")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Clean Up This Group?", isPresented: Binding(get: { confirmGroup != nil }, set: { if !$0 { confirmGroup = nil } }), titleVisibility: .visible) {
            if let g = confirmGroup {
                Button("Move \(g.removeIds.count) Cop\(g.removeIds.count == 1 ? "y" : "ies") to Recently Deleted", role: .destructive) {
                    withAnimation(LumiMotion.glide) { _ = service.resolve(g) }
                    confirmGroup = nil
                }
                Button("Cancel", role: .cancel) { confirmGroup = nil }
            }
        } message: {
            Text("The kept copy takes over their favorites and playlist places. You can undo this from Clean-up History for 30 days.")
        }
        .confirmationDialog("Clean Up All Safe Groups?", isPresented: $showCleanAllConfirm, titleVisibility: .visible) {
            Button("Clean Up \(service.safeGroups.count) Group\(service.safeGroups.count == 1 ? "" : "s")", role: .destructive) {
                withAnimation(LumiMotion.glide) { _ = service.resolveAllSafe() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only groups the engine is sure about — identical files, same source or same recording — with nothing to warn about. \"Likely\" matches stay for you to review.")
        }
    }

    // MARK: Summary

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(service.groups.count)")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .foregroundStyle(service.groups.isEmpty ? AppTheme.success : AppTheme.textPrimary)
                        .contentTransition(.numericText())
                    Text(service.groups.count == 1 ? "duplicate group" : "duplicate groups")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.textSecondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(service.groups.reduce(0) { $0 + $1.reclaimBytes }), countStyle: .file))
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppTheme.dynamicAccent)
                    Text("can be freed")
                        .font(.caption)
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }

            if service.isScanning {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: service.progress)
                        .tint(AppTheme.dynamicAccent)
                    Text(service.phase.isEmpty ? "Scanning…" : "\(service.phase)…")
                        .font(.caption)
                        .foregroundStyle(AppTheme.textSecondary)
                }
            } else {
                HStack(spacing: 10) {
                    Button {
                        Task { await service.scan() }
                    } label: {
                        Label("Scan Library", systemImage: "arrow.triangle.2.circlepath")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppTheme.textPrimary)

                    if !service.safeGroups.isEmpty {
                        Button {
                            showCleanAllConfirm = true
                        } label: {
                            Label("Clean Up \(service.safeGroups.count)", systemImage: "sparkles")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(AppTheme.dynamicAccent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                    }
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "clock").font(.caption2)
                if let date = service.lastScanDate {
                    Text("Scanned \(date, style: .relative) ago")
                } else {
                    Text("Not scanned yet")
                }
                if let r = service.report, r.pendingPrints > 0 {
                    Text("· \(r.pendingPrints) songs still to listen to — the next scan continues")
                }
            }
            .font(.caption2)
            .foregroundStyle(AppTheme.textSecondary)
            .lineLimit(2)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(AppTheme.surface))
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(nil, "All", count: service.groups.count)
                ForEach([DupeKind.exactFile, .sameSource, .sameRecording, .likelySame], id: \.self) { kind in
                    let n = service.groups.filter { $0.kind == kind }.count
                    if n > 0 { chip(kind, kind.label, count: n) }
                }
            }
        }
    }

    private func chip(_ kind: DupeKind?, _ title: String, count: Int) -> some View {
        let on = filter == kind
        return Button {
            withAnimation(LumiMotion.fade(0.15)) { filter = kind }
        } label: {
            HStack(spacing: 5) {
                if let kind { Image(systemName: kind.symbol).font(.caption2) }
                Text(title).font(.caption.weight(.semibold))
                Text("\(count)").font(.caption2.monospacedDigit()).opacity(0.7)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .foregroundStyle(on ? .white : AppTheme.textPrimary)
            .background(on ? AppTheme.dynamicAccent : AppTheme.elevatedSurface, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var allClearCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 40))
                .foregroundStyle(AppTheme.success)
            Text("No duplicates")
                .font(AppTheme.headlineFont(size: 16))
                .foregroundStyle(AppTheme.textPrimary)
            Text("Every track checked out as unique — by file, source and sound.")
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(AppTheme.surface))
    }

    // MARK: History

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Clean-up History", systemImage: "clock.arrow.circlepath")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)
            ForEach(service.journal.prefix(20), id: \.id) { r in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.keeperTitle)
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.textPrimary)
                            .lineLimit(1)
                        Text("\(r.removed.count) cop\(r.removed.count == 1 ? "y" : "ies") · \(ByteCountFormatter.string(fromByteCount: Int64(r.bytes), countStyle: .file)) · \(Date(timeIntervalSince1970: r.at), style: .relative) ago")
                            .font(.caption2)
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    Spacer()
                    Button("Undo") { withAnimation(LumiMotion.glide) { service.undo(r) } }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.bordered)
                        .tint(AppTheme.dynamicAccent)
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(AppTheme.surface))
    }

    private var ignoredFooter: some View {
        HStack {
            Text("\(ignoredCount) pair\(ignoredCount == 1 ? "" : "s") marked \"Not duplicates\"")
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
            Spacer()
            Button("Reset") {
                dupeUnignoreAll()
                ignoredCount = 0
                Task { await service.scan() }
            }
            .font(.caption.weight(.semibold))
            .tint(AppTheme.dynamicAccent)
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - Group card

struct DupeGroupCard: View {
    let group: DupeGroup
    var onKeep: (String) -> Void
    var onCleanUp: () -> Void
    var onIgnore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: group.kind.symbol)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(tint, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(group.kind.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(group.evidence.first ?? "")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(2)
                }
                Spacer()
                ConfidenceRing(value: Double(group.confidence), tint: tint)
            }

            VStack(spacing: 8) {
                ForEach(group.copies, id: \.id) { copy in
                    DupeCopyRow(copy: copy, song: DuplicateFinderService.shared.song(copy.id), isKeeper: copy.id == group.keeperId) {
                        withAnimation(LumiMotion.fade(0.18)) { onKeep(copy.id) }
                    }
                }
            }

            HStack(spacing: 10) {
                Button(action: onIgnore) {
                    Text("Not Duplicates")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(AppTheme.elevatedSurface, in: Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.textPrimary)
                Button(action: onCleanUp) {
                    Text(group.removeIds.isEmpty ? "Nothing to Remove" : "Keep 1 · Remove \(group.removeIds.count)")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(group.removeIds.isEmpty ? AppTheme.elevatedSurface : tint, in: Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(group.removeIds.isEmpty ? AppTheme.textSecondary : .white)
                .disabled(group.removeIds.isEmpty)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(AppTheme.surface))
    }

    private var tint: Color {
        switch group.kind {
        case .exactFile: return .teal
        case .sameSource: return .blue
        case .sameRecording: return .purple
        case .likelySame: return .orange
        }
    }
}

private struct ConfidenceRing: View {
    let value: Double
    let tint: Color

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.18), lineWidth: 3)
            Circle().trim(from: 0, to: value).stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
            Text("\(Int((value * 100).rounded()))")
                .font(.system(size: 10, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(AppTheme.textPrimary)
        }
        .frame(width: 32, height: 32)
        .accessibilityLabel("\(Int((value * 100).rounded())) percent sure")
    }
}

private struct DupeCopyRow: View {
    let copy: DupeCopy
    let song: Song?
    let isKeeper: Bool
    var onKeep: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onKeep) {
                Image(systemName: isKeeper ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isKeeper ? AppTheme.success : AppTheme.textSecondary.opacity(0.6))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isKeeper ? "Kept copy" : "Keep this copy")

            VStack(alignment: .leading, spacing: 4) {
                Text(song?.displayName ?? "Missing song")
                    .font(.subheadline.weight(isKeeper ? .semibold : .regular))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                Text(meta)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)
                FlowChips(good: copy.strengths, bad: copy.warnings)
            }
            Spacer(minLength: 0)
            if isKeeper {
                Text("KEEP")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(AppTheme.success)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(AppTheme.success.opacity(0.15), in: Capsule())
            } else if !copy.removable || copy.protected {
                Text(copy.protected ? "PLAYING" : "LOCKED")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(AppTheme.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(AppTheme.elevatedSurface, in: Capsule())
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isKeeper ? AppTheme.success.opacity(0.08) : AppTheme.elevatedSurface.opacity(0.6))
        )
    }

    private var meta: String {
        var parts: [String] = []
        if let song { parts.append(song.artistName) }
        parts.append(copy.format.uppercased())
        if let song, song.duration > 0 { parts.append(song.durationText) }
        if copy.fileSize > 0 { parts.append(ByteCountFormatter.string(fromByteCount: Int64(copy.fileSize), countStyle: .file)) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// Strength (green) and warning (orange) chips, wrapping.
private struct FlowChips: View {
    let good: [String]
    let bad: [String]

    var body: some View {
        let items = bad.map { ($0, false) } + good.map { ($0, true) }
        if !items.isEmpty {
            WrapLayout(spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Text(item.0)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(item.1 ? AppTheme.success : Color.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background((item.1 ? AppTheme.success : Color.orange).opacity(0.12), in: Capsule())
                }
            }
        }
    }
}

/// Minimal wrapping layout for chips.
private struct WrapLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += row + spacing
                x = 0
                row = 0
            }
            x += size.width + spacing
            row = max(row, size.height)
            maxX = max(maxX, x - spacing)
        }
        return CGSize(width: min(maxX, width), height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += row + spacing
                x = bounds.minX
                row = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}
