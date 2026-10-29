import AppKit
import Foundation
import Observation
import UserNotifications

@MainActor
@Observable
final class DownloadJob: Identifiable {
    enum State: Equatable {
        case queued, running, finished, stopped
        case failed(String)
    }

    let id = UUID()
    let channelName: String
    let title: String
    let start: Date
    let end: Date
    let sourceURL: String
    let output: URL

    var state: State = .queued
    var elapsed: Int = 0
    var bytes: Int64 = 0
    var log: [String] = []
    var startedAt: Date?

    var totalSeconds: Int { max(1, Int(end.timeIntervalSince(start))) }
    var progress: Double { min(1, Double(elapsed) / Double(totalSeconds)) }

    @ObservationIgnored fileprivate var process: Process?
    @ObservationIgnored fileprivate var stopRequested = false

    init(channelName: String, title: String, start: Date, end: Date, sourceURL: String, output: URL) {
        self.channelName = channelName
        self.title = title
        self.start = start
        self.end = end
        self.sourceURL = sourceURL
        self.output = output
    }

    var isActive: Bool { state == .queued || state == .running }

    /// Vitesse vs temps réel (ex. « ×8,2 »).
    var speedLabel: String? {
        guard state == .running, let startedAt, elapsed > 0 else { return nil }
        let wall = Date().timeIntervalSince(startedAt)
        guard wall > 2 else { return nil }
        return String(format: "×%.1f", locale: DateFormats.appLocale, Double(elapsed) / wall)
    }
}

@MainActor
@Observable
final class DownloadManager {
    private(set) var jobs: [DownloadJob] = []
    var maxConcurrent: Int = UserDefaults.standard.object(forKey: "maxConcurrent") as? Int ?? 2 {
        didSet { UserDefaults.standard.set(maxConcurrent, forKey: "maxConcurrent"); pump() }
    }

    var activeCount: Int { jobs.filter(\.isActive).count }

    // MARK: ffmpeg

    static func findFFmpeg(custom: String?) -> String? {
        var candidates: [String] = []
        if let custom, !custom.isEmpty { candidates.append(custom) }
        candidates += ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg"]
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        candidates += path.split(separator: ":").map { "\($0)/ffmpeg" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: Queue

    func enqueue(channel: LiveStream, title: String?, start: Date, end: Date, config: XtreamConfig, serverOffset: TimeInterval) throws {
        let client = XtreamClient(config: config)
        let url = client.catchupURL(streamID: channel.streamID, start: start, end: end, serverOffset: serverOffset)
        let output = try Self.outputURL(dir: config.outputDirectory, channel: channel.name, title: title, start: start, end: end,
                                        reserved: Set(jobs.filter(\.isActive).map(\.output)))
        let job = DownloadJob(channelName: channel.name, title: title ?? String(localized: "Plage manuelle"),
                              start: start, end: end, sourceURL: url, output: output)
        jobs.insert(job, at: 0)
        pump(ffmpegPath: config.ffmpegPath)
    }

    func stop(_ job: DownloadJob) {
        switch job.state {
        case .queued:
            job.state = .stopped
        case .running:
            job.stopRequested = true
            job.process?.interrupt()  // SIGINT : ffmpeg finalise proprement le .mp4
        default: break
        }
        pump()
    }

    func retry(_ job: DownloadJob, ffmpegPath: String?) {
        guard !job.isActive else { return }
        job.state = .queued
        job.elapsed = 0
        job.bytes = 0
        job.log = []
        job.stopRequested = false
        pump(ffmpegPath: ffmpegPath)
    }

    func remove(_ job: DownloadJob) {
        if job.isActive { stop(job) }
        jobs.removeAll { $0.id == job.id }
    }

    func clearFinished() {
        jobs.removeAll { !$0.isActive }
    }

    func stopAll() {
        for job in jobs where job.isActive { stop(job) }
    }

    private var lastFFmpegPath: String?

    private func pump(ffmpegPath: String? = nil) {
        if let ffmpegPath { lastFFmpegPath = ffmpegPath }
        let running = jobs.filter { $0.state == .running }.count
        guard running < maxConcurrent else { return }
        let next = jobs.reversed().filter { $0.state == .queued }.prefix(maxConcurrent - running)
        for job in next { launch(job) }
    }

    private func launch(_ job: DownloadJob) {
        guard let ffmpeg = Self.findFFmpeg(custom: lastFFmpegPath) else {
            job.state = .failed(String(localized: "FFmpeg introuvable. Installez-le avec « brew install ffmpeg »."))
            return
        }
        try? FileManager.default.createDirectory(at: job.output.deletingLastPathComponent(), withIntermediateDirectories: true)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpeg)
        proc.arguments = [
            "-hide_banner", "-nostdin", "-y",
            "-loglevel", "warning",
            "-progress", "pipe:1", "-nostats",
            "-reconnect", "1", "-reconnect_streamed", "1", "-reconnect_delay_max", "10",
            "-i", job.sourceURL,
            // Uniquement vidéo + audio : les flux IPTV contiennent souvent du télétexte, des
            // sous-titres DVB ou des données (SCTE-35) que le MP4 refuse (« Invalid argument »).
            "-map", "0:v?", "-map", "0:a?", "-sn", "-dn", "-ignore_unknown",
            // Vidéo copiée telle quelle ; audio réencodé en AAC car la TNT diffuse souvent en MP2,
            // que QuickTime / les apps Apple ne lisent pas dans un MP4 (vidéo muette).
            "-c:v", "copy",
            "-c:a", "aac", "-b:a", "192k",
            "-movflags", "+faststart",
            job.output.path,
        ]

        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        proc.standardInput = FileHandle.nullDevice

        let progressLines = LineBuffer { line in
            Task { @MainActor in job.handleProgress(line) }
        }
        let errorLines = LineBuffer { line in
            Task { @MainActor in job.appendLog(line) }
        }
        out.fileHandleForReading.readabilityHandler = { h in progressLines.feed(h.availableData) }
        err.fileHandleForReading.readabilityHandler = { h in errorLines.feed(h.availableData) }

        proc.terminationHandler = { p in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            // Récupère ce qui reste dans les tuyaux avant de conclure.
            progressLines.feed(out.fileHandleForReading.readDataToEndOfFile())
            errorLines.feed(err.fileHandleForReading.readDataToEndOfFile())
            errorLines.feed(Data([0x0A]))
            let status = p.terminationStatus
            Task { @MainActor in self.finish(job, status: status) }
        }

        do {
            job.appendLog("$ ffmpeg -i \(job.sourceURL) → \(job.output.lastPathComponent)")
            try proc.run()
            job.process = proc
            job.state = .running
            job.startedAt = Date()
        } catch {
            job.state = .failed(String(localized: "Impossible de lancer FFmpeg : \(error.localizedDescription)"))
        }
    }

    private func finish(_ job: DownloadJob, status: Int32) {
        job.process = nil
        let size = (try? job.output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

        if job.stopRequested {
            job.state = .stopped
        } else if status == 0 && size > 0 {
            // Le job reste « running » pendant le recalage, puis passe à « finished ».
            let ffmpeg = Self.findFFmpeg(custom: lastFFmpegPath)
            let output = job.output
            Task.detached {
                if let ffmpeg { Self.trimToFirstVideoFrame(output, ffmpeg: ffmpeg) }
                await MainActor.run {
                    job.elapsed = job.totalSeconds
                    job.state = .finished
                    Notifier.send(title: String(localized: "Téléchargement terminé"), body: "\(job.channelName) — \(job.title)")
                }
            }
            return
        } else {
            // La vraie cause est souvent sur la ligne qui précède le « Error … » générique de ffmpeg.
            let lines = job.log.filter { !$0.hasPrefix("$ ") }
            let hint: String?
            if let i = lines.lastIndex(where: { $0.contains("Server returned") || $0.lowercased().contains("error") }) {
                hint = lines[max(0, i - 1)...i].joined(separator: "\n")
            } else {
                hint = lines.last
            }
            job.state = .failed(hint ?? String(localized: "FFmpeg a terminé avec le code \(status)."))
            Notifier.send(title: String(localized: "Échec du téléchargement"), body: "\(job.channelName) — \(job.title)")
        }
        pump()
    }

    // MARK: Recalage du début

    /// Un replay commence rarement sur une image clé : ffmpeg écarte la vidéo jusqu'à la première
    /// mais garde le son, d'où ~1 s d'écran noir au début. On recoupe le fichier sur cette image.
    nonisolated static func trimToFirstVideoFrame(_ file: URL, ffmpeg: String) {
        let ffprobe = URL(fileURLWithPath: ffmpeg).deletingLastPathComponent().appendingPathComponent("ffprobe").path
        guard FileManager.default.isExecutableFile(atPath: ffprobe),
              let probe = runTool(ffprobe, ["-v", "error", "-show_entries", "stream=codec_type,start_time",
                                            "-of", "csv=p=0", file.path])
        else { return }

        var starts: [String: Double] = [:]
        for line in probe.split(whereSeparator: \.isNewline) {
            let f = line.split(separator: ",").map(String.init)
            if f.count == 2, let t = Double(f[1]), starts[f[0]] == nil { starts[f[0]] = t }
        }
        guard let video = starts["video"], let audio = starts["audio"], video - audio > 0.1 else { return }

        let tmp = file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent).tmp.mp4")
        let ok = runTool(ffmpeg, ["-hide_banner", "-nostdin", "-v", "error", "-y",
                                  "-ss", String(format: "%.3f", video), "-i", file.path,
                                  "-map", "0", "-c", "copy", "-movflags", "+faststart", tmp.path]) != nil
        let size = (try? tmp.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if ok && size > 0 {
            _ = try? FileManager.default.replaceItemAt(file, withItemAt: tmp)
        } else {
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    /// Lance un outil et renvoie sa sortie standard, ou nil s'il échoue.
    nonisolated private static func runTool(_ path: String, _ args: [String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return proc.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }

    // MARK: Nom de fichier

    static func outputURL(dir: URL, channel: String, title: String?, start: Date, end: Date, reserved: Set<URL>) throws -> URL {
        func clean(_ s: String) -> String {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
            let mapped = s.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
            return String(mapped).replacingOccurrences(of: #"_+"#, with: "_", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        }
        var name = "\(clean(channel))_\(DateFormats.string(start, "yyyy-MM-dd"))_\(DateFormats.string(start, "HHmm"))-\(DateFormats.string(end, "HHmm"))"
        if let title, !title.isEmpty { name += "_" + String(clean(title).prefix(60)) }

        var candidate = dir.appendingPathComponent(name + ".mp4")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) || reserved.contains(candidate) {
            candidate = dir.appendingPathComponent("\(name)-\(n).mp4")
            n += 1
        }
        return candidate
    }
}

extension DownloadJob {
    func handleProgress(_ line: String) {
        // Sortie de -progress : clé=valeur, une par ligne.
        let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        switch parts[0] {
        case "out_time_us", "out_time_ms":  // out_time_ms est en µs aussi (bug historique de ffmpeg)
            if let us = Int64(parts[1]), us > 0 { elapsed = Int(us / 1_000_000) }
        case "total_size":
            if let b = Int64(parts[1]) { bytes = b }
        default: break
        }
    }

    func appendLog(_ line: String) {
        log.append(line)
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }
}

/// Découpe un flux d'octets en lignes (thread-safe).
final class LineBuffer: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()
    private let onLine: (String) -> Void

    init(onLine: @escaping (String) -> Void) { self.onLine = onLine }

    func feed(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        buffer.append(data)
        var lines: [String] = []
        while let idx = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = buffer.subdata(in: buffer.startIndex..<idx)
            buffer.removeSubrange(buffer.startIndex...idx)
            if let s = String(data: lineData, encoding: .utf8), !s.isEmpty { lines.append(s) }
        }
        lock.unlock()
        lines.forEach(onLine)
    }
}

enum Notifier {
    static func requestAuthorization() {
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func send(title: String, body: String) {
        // Les notifications ne fonctionnent que dans un vrai bundle .app.
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            NSSound.beep()
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
