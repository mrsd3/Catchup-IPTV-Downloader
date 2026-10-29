import SwiftUI

struct ChannelDetailView: View {
    let stream: LiveStream

    @Environment(AppStore.self) private var store
    @Environment(DownloadManager.self) private var downloads

    enum Mode: String, CaseIterable, Identifiable {
        case guide = "Programmes", manual = "Plage personnalisée"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .guide
    @State private var selectedDay: Date?
    @State private var errorMessage: String?
    @AppStorage("marginBefore") private var marginBefore = 2
    @AppStorage("marginAfter") private var marginAfter = 5

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !stream.hasArchive {
                ContentUnavailableView("Pas de replay sur cette chaîne",
                                       systemImage: "clock.badge.xmark",
                                       description: Text("Le fournisseur n'a pas activé le catchup (tv_archive) pour « \(stream.name) »."))
            } else {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 360)
                .padding(.vertical, 10)

                switch mode {
                case .guide: guide
                case .manual:
                    ManualRangeView(stream: stream) { start, end in
                        enqueue(title: nil, start: start, end: end)
                    }
                }
            }
        }
        .navigationTitle(stream.name)
        .task { await store.loadEPG(for: stream) }
        .alert("Impossible de lancer le téléchargement",
               isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            ChannelLogo(url: stream.icon, size: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(stream.name).font(.title2.weight(.semibold)).lineLimit(1)
                HStack(spacing: 8) {
                    if let cat = store.categoryName(for: stream) {
                        Text(cat)
                    }
                    if stream.hasArchive {
                        Label {
                            stream.archiveDays > 0 ? Text("Replay sur \(stream.archiveDays) jours") : Text("Replay disponible")
                        } icon: {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                store.toggleFavorite(stream)
            } label: {
                Image(systemName: store.favorites.contains(stream.streamID) ? "star.fill" : "star")
                    .foregroundStyle(store.favorites.contains(stream.streamID) ? Color.yellow : Color.secondary)
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .help("Favori")
        }
        .padding(16)
    }

    // MARK: Guide (EPG)

    private var entries: [EPGEntry] { store.epg[stream.streamID] ?? [] }

    private var days: [Date] {
        let cal = Calendar.current
        let limit = stream.archiveDays > 0
            ? cal.date(byAdding: .day, value: -stream.archiveDays, to: cal.startOfDay(for: Date()))!
            : .distantPast
        let set = Set(entries.map { cal.startOfDay(for: $0.start) }).filter { $0 >= limit }
        return set.sorted()
    }

    private var currentDay: Date? {
        if let selectedDay, days.contains(selectedDay) { return selectedDay }
        let today = Calendar.current.startOfDay(for: Date())
        return days.contains(today) ? today : days.last
    }

    @ViewBuilder
    private var guide: some View {
        switch store.epgState[stream.streamID] ?? .loading {
        case .loading where entries.isEmpty:
            ProgressView("Chargement du guide…").frame(maxHeight: .infinity)
        case .failed(let msg) where entries.isEmpty:
            ContentUnavailableView {
                Label("Guide indisponible", systemImage: "list.bullet.rectangle")
            } description: {
                Text(msg)
            } actions: {
                Button("Réessayer") { Task { await store.loadEPG(for: stream, force: true) } }
                Button("Plage personnalisée") { mode = .manual }
            }
        default:
            if entries.isEmpty {
                ContentUnavailableView {
                    Label("Aucun programme", systemImage: "list.bullet.rectangle")
                } description: {
                    Text("Le fournisseur ne fournit pas de guide pour cette chaîne. Utilisez une plage personnalisée.")
                } actions: {
                    Button("Plage personnalisée") { mode = .manual }
                }
            } else {
                dayStrip
                Divider()
                programList
                Divider()
                marginBar
            }
        }
    }

    private var dayStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(days, id: \.self) { day in
                        let selected = day == currentDay
                        Button {
                            selectedDay = day
                        } label: {
                            Text(dayLabel(day))
                                .font(.callout.weight(selected ? .semibold : .regular))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(selected ? Color.accentColor : Color.primary.opacity(0.06)))
                                .foregroundStyle(selected ? Color.white : Color.primary)
                        }
                        .buttonStyle(.plain)
                        .id(day)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
            .onAppear { if let d = currentDay { proxy.scrollTo(d, anchor: .center) } }
        }
    }

    private var programList: some View {
        let cal = Calendar.current
        let dayEntries = entries.filter { e in currentDay.map { cal.isDate(e.start, inSameDayAs: $0) } ?? false }

        return ScrollViewReader { proxy in
            List {
                ForEach(dayEntries) { entry in
                    ProgramRow(entry: entry,
                               job: job(for: entry),
                               canDownload: canDownload(entry)) {
                        enqueue(title: entry.title,
                                start: entry.start.addingTimeInterval(TimeInterval(-marginBefore * 60)),
                                end: min(Date(), entry.end.addingTimeInterval(TimeInterval(marginAfter * 60))))
                    }
                    .id(entry.id)
                }
            }
            .listStyle(.inset)
            .onAppear {
                if let live = dayEntries.last(where: { $0.isPast }) { proxy.scrollTo(live.id, anchor: .bottom) }
            }
        }
    }

    private var marginBar: some View {
        // Version compacte quand la colonne est étroite, pour ne pas imposer de largeur mini à la fenêtre.
        ViewThatFits(in: .horizontal) {
            marginBarContent(compact: false)
            marginBarContent(compact: true)
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func marginBarContent(compact: Bool) -> some View {
        HStack(spacing: compact ? 10 : 16) {
            Stepper(value: $marginBefore, in: 0...30) {
                compact ? Text("Avant : \(marginBefore) min") : Text("Marge avant : \(marginBefore) min")
            }
            Stepper(value: $marginAfter, in: 0...60) {
                compact ? Text("Après : \(marginAfter) min") : Text("Marge après : \(marginAfter) min")
            }
            Spacer(minLength: 0)
            Button {
                Task { await store.loadEPG(for: stream, force: true) }
            } label: {
                if compact {
                    Image(systemName: "arrow.clockwise")
                } else {
                    Label("Actualiser le guide", systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .help("Actualiser le guide")
        }
    }

    private func dayLabel(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return String(localized: "Aujourd'hui") }
        if cal.isDateInYesterday(day) { return String(localized: "Hier") }
        if cal.isDateInTomorrow(day) { return String(localized: "Demain") }
        return DateFormats.dayHeader.string(from: day).capitalized(with: DateFormats.appLocale)
    }

    private func canDownload(_ entry: EPGEntry) -> Bool {
        guard entry.isPast else { return false }
        if stream.archiveDays > 0,
           entry.start < Date().addingTimeInterval(TimeInterval(-stream.archiveDays * 86_400)) { return false }
        return true
    }

    private func job(for entry: EPGEntry) -> DownloadJob? {
        downloads.jobs.first {
            $0.channelName == stream.name && $0.title == entry.title
                && abs($0.start.timeIntervalSince(entry.start)) < 3600
                && $0.state != .stopped
        }
    }

    private func enqueue(title: String?, start: Date, end: Date) {
        guard let config = store.config else { return }
        guard end > start else { errorMessage = String(localized: "La fin doit être après le début."); return }
        do {
            try downloads.enqueue(channel: stream, title: title, start: start, end: end,
                                  config: config, serverOffset: store.serverOffset)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Ligne de programme

struct ProgramRow: View {
    let entry: EPGEntry
    let job: DownloadJob?
    let canDownload: Bool
    let onDownload: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(DateFormats.time.string(from: entry.start))
                    .font(.body.monospacedDigit().weight(.medium))
                Text(DateFormats.durationLabel(entry.duration))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 56, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.title).font(.body.weight(.medium)).lineLimit(1)
                    if entry.isLive {
                        Text("EN DIRECT")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(.red))
                            .foregroundStyle(.white)
                    }
                }
                if !entry.summary.isEmpty {
                    Text(entry.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(hovering ? 6 : 2)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 4)
        .opacity(entry.isPast || entry.isLive ? 1 : 0.45)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: hovering)
    }

    @ViewBuilder
    private var trailing: some View {
        if let job {
            switch job.state {
            case .queued:
                Image(systemName: "clock").foregroundStyle(.secondary).help("En file d'attente")
            case .running:
                ProgressView(value: job.progress)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .help("\(Int(job.progress * 100)) %")
            case .finished:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Téléchargé")
            case .failed:
                Button(action: onDownload) {
                    Image(systemName: "exclamationmark.arrow.circlepath").foregroundStyle(.orange)
                }
                .buttonStyle(.borderless)
                .help("Échec — relancer")
            case .stopped:
                downloadButton
            }
        } else if canDownload {
            downloadButton
        } else if entry.isLive {
            Text("En cours").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var downloadButton: some View {
        Button(action: onDownload) {
            Image(systemName: "arrow.down.circle")
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
        }
        .buttonStyle(.borderless)
        .help("Télécharger ce programme")
    }
}
