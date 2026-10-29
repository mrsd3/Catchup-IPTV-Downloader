import Foundation

// MARK: - Config (compatible avec ~/.catchup_config.json du script Python)

struct XtreamConfig: Codable, Equatable {
    var host: String
    var port: String
    var username: String
    var password: String
    var urlFormat: Int = 4
    var outputDir: String? = nil
    var ffmpegPath: String? = nil

    enum CodingKeys: String, CodingKey {
        case host, port, username, password
        case urlFormat = "url_format"
        case outputDir = "output_dir"
        case ffmpegPath = "ffmpeg_path"
    }

    init(host: String = "", port: String = "", username: String = "", password: String = "") {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = c.flexString(.host) ?? ""
        port = c.flexString(.port) ?? ""
        username = c.flexString(.username) ?? ""
        password = c.flexString(.password) ?? ""
        urlFormat = c.flexInt(.urlFormat) ?? 4
        outputDir = c.flexString(.outputDir)
        ffmpegPath = c.flexString(.ffmpegPath)
    }

    /// Même normalisation que le script Python.
    mutating func normalize() {
        host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        while host.hasSuffix("/") { host.removeLast() }
        if !host.lowercased().hasPrefix("http") { host = "http://" + host }
        if let r = host.range(of: #":(\d+)$"#, options: .regularExpression) {
            if port.isEmpty { port = String(host[r].dropFirst()) }
            host.removeSubrange(r)
        }
        port = port.trimmingCharacters(in: .whitespacesAndNewlines)
        username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        password = password.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var baseURL: String { port.isEmpty ? host : "\(host):\(port)" }

    var outputDirectory: URL {
        if let dir = outputDir, !dir.isEmpty { return URL(fileURLWithPath: dir) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".catchup_config.json")

    static func load() -> XtreamConfig? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(XtreamConfig.self, from: data)
    }

    func save() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: Self.fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.fileURL.path)
    }
}

// MARK: - Xtream objects

struct LiveCategory: Decodable, Identifiable, Hashable {
    let id: String
    let name: String

    enum CodingKeys: String, CodingKey { case id = "category_id", name = "category_name" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.flexString(.id) ?? UUID().uuidString
        name = c.flexString(.name) ?? String(localized: "Sans nom")
    }
}

struct LiveStream: Decodable, Identifiable, Hashable {
    let streamID: Int
    let name: String
    let icon: URL?
    let categoryID: String?
    let hasArchive: Bool
    let archiveDays: Int

    var id: Int { streamID }

    enum CodingKeys: String, CodingKey {
        case streamID = "stream_id", name, icon = "stream_icon", categoryID = "category_id"
        case tvArchive = "tv_archive", archiveDuration = "tv_archive_duration"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let sid = c.flexInt(.streamID) else {
            throw DecodingError.dataCorruptedError(forKey: .streamID, in: c, debugDescription: "stream_id manquant")
        }
        streamID = sid
        name = (c.flexString(.name) ?? String(localized: "Chaîne \(sid)")).trimmingCharacters(in: .whitespaces)
        if let s = c.flexString(.icon), !s.isEmpty { icon = URL(string: s) } else { icon = nil }
        categoryID = c.flexString(.categoryID)
        hasArchive = (c.flexInt(.tvArchive) ?? 0) == 1
        archiveDays = c.flexInt(.archiveDuration) ?? 0
    }
}

struct EPGEntry: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    let summary: String
    /// Début/fin réels (instant absolu).
    let start: Date
    let end: Date
    let hasArchive: Bool
    /// Écart entre l'heure du serveur et l'heure du Mac, déduit de "start" vs "start_timestamp".
    let serverOffset: TimeInterval?

    var duration: TimeInterval { end.timeIntervalSince(start) }
    var isPast: Bool { end <= Date() }
    var isLive: Bool { start <= Date() && Date() < end }

    enum CodingKeys: String, CodingKey {
        case id, title, description, start, end
        case stop, startTimestamp = "start_timestamp", stopTimestamp = "stop_timestamp"
        case hasArchive = "has_archive"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedTitle = Self.decodeBase64(c.flexString(.title)) ?? String(localized: "Sans titre")
        title = decodedTitle
        summary = Self.decodeBase64(c.flexString(.description)) ?? ""
        hasArchive = (c.flexInt(.hasArchive) ?? 0) == 1

        let wallStart = c.flexString(.start).flatMap(DateFormats.parseServer)
        let wallEnd = (c.flexString(.end) ?? c.flexString(.stop)).flatMap(DateFormats.parseServer)
        let tsStart = c.flexInt(.startTimestamp).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        let tsEnd = c.flexInt(.stopTimestamp).map { Date(timeIntervalSince1970: TimeInterval($0)) }

        guard let s = tsStart ?? wallStart else {
            throw DecodingError.dataCorruptedError(forKey: .start, in: c, debugDescription: "start manquant")
        }
        start = s
        if let e = tsEnd {
            end = e
        } else if let ws = wallStart, let we = wallEnd {
            end = s.addingTimeInterval(we.timeIntervalSince(ws))
        } else {
            end = s.addingTimeInterval(3600)
        }

        // Les chaînes "start" sont en heure locale du serveur ; les timestamps sont en UTC.
        // Leur différence (arrondie au quart d'heure) donne le décalage serveur ↔ Mac.
        if let ws = wallStart, let ts = tsStart {
            let raw = ws.timeIntervalSince(ts)
            serverOffset = (raw / 900).rounded() * 900
        } else {
            serverOffset = nil
        }
        let stamp = Int(s.timeIntervalSince1970)
        if let rawID = c.flexString(.id) {
            id = "\(rawID)-\(stamp)"
        } else {
            id = "\(stamp)-\(decodedTitle)"
        }
    }

    private static func decodeBase64(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        if let d = Data(base64Encoded: s, options: .ignoreUnknownCharacters),
           let txt = String(data: d, encoding: .utf8), !txt.isEmpty {
            return txt.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }
}

// MARK: - Helpers

enum DateFormats {
    static let server: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func parseServer(_ s: String) -> Date? {
        if let d = server.date(from: s) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: s)
    }

    static func string(_ date: Date, _ format: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = format
        return f.string(from: date)
    }

    /// Langue effectivement utilisée par l'app (celle choisie dans Réglages, sinon celle du système).
    static let appLocale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "fr")

    static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = appLocale
        f.dateFormat = "HH:mm"
        return f
    }()

    static let dayHeader: DateFormatter = {
        let f = DateFormatter()
        f.locale = appLocale
        f.setLocalizedDateFormatFromTemplate("EEEEdMMMM")  // « lundi 26 octobre » / « Monday, October 26 »
        return f
    }()

    static func durationLabel(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600, m = (total % 3600) / 60
        if h > 0 { return m > 0 ? "\(h) h \(String(format: "%02d", m))" : "\(h) h" }
        return "\(m) min"
    }

    static func clock(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

extension KeyedDecodingContainer {
    func flexInt(_ key: Key) -> Int? {
        if let v = try? decodeIfPresent(Int.self, forKey: key) { return v }
        if let s = try? decodeIfPresent(String.self, forKey: key) {
            return Int(s.trimmingCharacters(in: .whitespaces))
        }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return Int(d) }
        return nil
    }

    func flexString(_ key: Key) -> String? {
        if let s = try? decodeIfPresent(String.self, forKey: key) { return s }
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return String(i) }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return String(d) }
        return nil
    }
}

/// Décode un tableau en ignorant les éléments invalides (les API Xtream sont souvent sales).
struct LossyArray<T: Decodable>: Decodable {
    let items: [T]
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        var out: [T] = []
        while !c.isAtEnd {
            let before = c.currentIndex
            if let v = try? c.decode(T.self) {
                out.append(v)
            } else {
                _ = try? c.decode(AnyDecodable.self)
                if c.currentIndex == before { break }  // sécurité anti-boucle
            }
        }
        items = out
    }
}

private struct AnyDecodable: Decodable {
    init(from decoder: Decoder) throws {}
}
