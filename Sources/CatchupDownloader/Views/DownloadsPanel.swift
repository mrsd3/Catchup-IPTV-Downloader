import AppKit
import SwiftUI

struct DownloadsPanel: View {
    @Environment(DownloadManager.self) private var downloads
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Téléchargements").font(.headline)
                Spacer()
                if downloads.jobs.contains(where: { !$0.isActive }) {
                    Button("Effacer") { downloads.clearFinished() }
                        .buttonStyle(.borderless)
                        .help("Retirer les téléchargements terminés de la liste")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()

            if downloads.jobs.isEmpty {
                ContentUnavailableView("Aucun téléchargement",
                                       systemImage: "arrow.down.circle",
                                       description: Text("Cliquez sur ⬇︎ à côté d'un programme pour le récupérer."))
            } else {
                List {
                    ForEach(downloads.jobs) { job in
                        DownloadRow(job: job, ffmpegPath: store.config?.ffmpegPath)
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            HStack {
                Button {
                    if let dir = store.config?.outputDirectory { NSWorkspace.shared.open(dir) }
                } label: {
                    Label(store.config?.outputDirectory.lastPathComponent ?? String(localized: "Dossier"), systemImage: "folder")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.borderless)
                .help("Ouvrir le dossier de destination")
                Spacer(minLength: 8)
                Text("Simultanés")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                Picker("", selection: Binding(get: { downloads.maxConcurrent }, set: { downloads.maxConcurrent = $0 })) {
                    ForEach(1...4, id: \.self) { Text("\($0)").tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(width: 380, height: downloads.jobs.isEmpty ? 240 : 420)
    }
}

struct DownloadRow: View {
    let job: DownloadJob
    let ffmpegPath: String?

    @Environment(DownloadManager.self) private var downloads
    @State private var showLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(job.title).font(.callout.weight(.medium)).lineLimit(1)
                    Text("\(job.channelName) · \(DateFormats.dayHeader.string(from: job.start)) \(DateFormats.time.string(from: job.start))–\(DateFormats.time.string(from: job.end))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                actions
                    .fixedSize()
            }

            switch job.state {
            case .queued:
                ProgressView().progressViewStyle(.linear)
                Text("En attente…").font(.caption).foregroundStyle(.secondary)
            case .running:
                ProgressView(value: job.progress)
                HStack(spacing: 4) {
                    Text("\(DateFormats.clock(job.elapsed)) / \(DateFormats.clock(job.totalSeconds))")
                    if job.bytes > 0 {
                        Text("· " + ByteCountFormatter.string(fromByteCount: job.bytes, countStyle: .file))
                    }
                    Spacer(minLength: 4)
                    if let speed = job.speedLabel { Text(speed).help("Vitesse par rapport au temps réel") }
                    Text("\(Int(job.progress * 100)) %").fixedSize()
                }
                .lineLimit(1)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            case .finished:
                Label("Terminé · \(job.output.lastPathComponent)", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .lineLimit(1)
                    .truncationMode(.middle)
            case .stopped:
                Label("Arrêté", systemImage: "stop.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .failed(let msg):
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Copier l'URL du flux") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(job.sourceURL, forType: .string)
            }
            Button("Afficher le journal FFmpeg") { showLog = true }
            Divider()
            Button("Retirer de la liste", role: .destructive) { downloads.remove(job) }
        }
        .popover(isPresented: $showLog, arrowEdge: .leading) {
            ScrollView {
                Text(job.log.joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .frame(width: 480, height: 300)
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 6) {
            switch job.state {
            case .queued, .running:
                iconButton("stop.circle.fill", "Arrêter") { downloads.stop(job) }
            case .finished:
                iconButton("play.circle", "Ouvrir") { NSWorkspace.shared.open(job.output) }
                iconButton("magnifyingglass.circle", "Afficher dans le Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([job.output])
                }
            case .failed, .stopped:
                if FileManager.default.fileExists(atPath: job.output.path) {
                    iconButton("magnifyingglass.circle", "Afficher dans le Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([job.output])
                    }
                }
                iconButton("arrow.clockwise.circle", "Relancer") { downloads.retry(job, ffmpegPath: ffmpegPath) }
            }
        }
    }

    private func iconButton(_ symbol: String, _ help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3)
                .symbolRenderingMode(.hierarchical)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}
