import Foundation

enum XtreamError: LocalizedError {
    case badURL
    case http(Int)
    case unreachable(String)
    case auth
    case unexpected(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "Adresse du serveur invalide."
        case .http(let code): return "Le serveur a répondu avec l'erreur HTTP \(code)."
        case .unreachable(let why): return "Impossible de joindre le serveur — \(why)"
        case .auth: return "Identifiants refusés par le serveur."
        case .unexpected(let what): return "Réponse inattendue de l'API (\(what))."
        }
    }
}

struct XtreamClient {
    let config: XtreamConfig

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.httpAdditionalHeaders = ["User-Agent": "VLC/3.0.20 LibVLC/3.0.20"]
        return URLSession(configuration: cfg)
    }()

    // MARK: API

    private func apiURL(_ action: String?, _ extra: [URLQueryItem] = []) throws -> URL {
        guard var comps = URLComponents(string: config.baseURL + "/player_api.php") else { throw XtreamError.badURL }
        var items = [
            URLQueryItem(name: "username", value: config.username),
            URLQueryItem(name: "password", value: config.password),
        ]
        if let action { items.append(URLQueryItem(name: "action", value: action)) }
        comps.queryItems = items + extra
        guard let url = comps.url else { throw XtreamError.badURL }
        return url
    }

    private func get(_ url: URL) async throws -> Data {
        do {
            let (data, resp) = try await Self.session.data(from: url)
            if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                if http.statusCode == 401 || http.statusCode == 403 { throw XtreamError.auth }
                throw XtreamError.http(http.statusCode)
            }
            return data
        } catch let e as XtreamError {
            throw e
        } catch let e as URLError {
            throw XtreamError.unreachable(e.localizedDescription)
        }
    }

    /// Vérifie les identifiants (player_api.php sans action → user_info).
    func authenticate() async throws {
        let data = try await get(try apiURL(nil))
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = obj["user_info"] as? [String: Any] else {
            throw XtreamError.unexpected("pas de user_info")
        }
        let auth = (info["auth"] as? Int) ?? Int("\(info["auth"] ?? "0")") ?? 0
        if auth != 1 { throw XtreamError.auth }
    }

    func liveCategories() async throws -> [LiveCategory] {
        let data = try await get(try apiURL("get_live_categories"))
        return (try? JSONDecoder().decode(LossyArray<LiveCategory>.self, from: data).items) ?? []
    }

    func liveStreams() async throws -> [LiveStream] {
        let data = try await get(try apiURL("get_live_streams"))
        do {
            return try JSONDecoder().decode(LossyArray<LiveStream>.self, from: data).items
        } catch {
            throw XtreamError.unexpected("pas une liste de chaînes")
        }
    }

    func epg(streamID: Int) async throws -> [EPGEntry] {
        let data = try await get(try apiURL("get_simple_data_table", [URLQueryItem(name: "stream_id", value: String(streamID))]))
        struct Wrapper: Decodable { let epg_listings: LossyArray<EPGEntry>? }
        let list = (try? JSONDecoder().decode(Wrapper.self, from: data))?.epg_listings?.items ?? []
        // Dédoublonnage + tri : certains serveurs renvoient des doublons.
        var seen = Set<String>()
        return list
            .filter { seen.insert("\(Int($0.start.timeIntervalSince1970))|\($0.title)").inserted }
            .sorted { $0.start < $1.start }
    }

    // MARK: Catchup URL (mêmes 5 formats que le script Python)

    /// - Parameters:
    ///   - start/end : instants réels.
    ///   - serverOffset : décalage horaire serveur − Mac (secondes).
    func catchupURL(streamID: Int, start: Date, end: Date, serverOffset: TimeInterval) -> String {
        let duration = max(1, Int((end.timeIntervalSince(start) / 60).rounded(.up)))
        let serverStart = start.addingTimeInterval(serverOffset)
        let serverEnd = end.addingTimeInterval(serverOffset)
        let base = config.baseURL
        let user = config.username
        let pwd = config.password
        let startStr = DateFormats.string(serverStart, "yyyy-MM-dd:HH-mm")

        func query(_ path: String, _ items: [(String, String)]) -> String {
            var comps = URLComponents(string: base + path)
            comps?.queryItems = items.map { URLQueryItem(name: $0.0, value: $0.1) }
            return comps?.url?.absoluteString ?? base + path
        }

        switch config.urlFormat {
        case 2:
            return query("/player_api.php", [
                ("username", user), ("password", pwd), ("action", "catchup"),
                ("channel", String(streamID)),
                ("start", DateFormats.string(serverStart, "yyyy-MM-dd HH:mm:ss")),
                ("end", DateFormats.string(serverEnd, "yyyy-MM-dd HH:mm:ss")),
            ])
        case 3:
            return query("/streaming/timeshift.php", [
                ("username", user), ("password", pwd), ("stream", String(streamID)),
                ("start", startStr), ("duration", String(duration)),
            ])
        case 4:
            let s4 = DateFormats.string(serverStart, "yyyy-MM-dd:HH:mm")
            return "\(base)/timeshift/\(user)/\(pwd)/\(duration)/\(s4)/\(streamID).ts"
        case 5:
            return "\(base)/timeshift/\(user)/\(pwd)/\(duration)/\(startStr)/\(streamID)"
        default:
            return "\(base)/timeshift/\(user)/\(pwd)/\(duration)/\(startStr)/\(streamID).ts"
        }
    }

    static let formatDescriptions: [(Int, String)] = [
        (1, "1 — /timeshift/…/AAAA-MM-JJ:HH-MM/id.ts (standard)"),
        (2, "2 — player_api.php?action=catchup"),
        (3, "3 — streaming/timeshift.php"),
        (4, "4 — /timeshift/…/AAAA-MM-JJ:HH:MM/id.ts"),
        (5, "5 — /timeshift/…/id (sans .ts)"),
    ]
}
