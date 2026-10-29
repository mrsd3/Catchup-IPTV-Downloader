import Foundation
import Observation
import SwiftUI

enum SidebarItem: Hashable {
    case all, catchup, favorites
    case category(String)
}

enum LoadState: Equatable {
    case idle, loading, loaded
    case failed(String)
}

@MainActor
@Observable
final class AppStore {
    var config: XtreamConfig?

    var categories: [LiveCategory] = []
    var streams: [LiveStream] = []
    var loadState: LoadState = .idle

    var sidebarSelection: SidebarItem? = .catchup
    var selectedStreamID: Int?
    var searchText = ""

    var epg: [Int: [EPGEntry]] = [:]
    var epgState: [Int: LoadState] = [:]

    /// Décalage horaire serveur − Mac, déduit automatiquement de l'EPG.
    var serverOffset: TimeInterval = UserDefaults.standard.double(forKey: "serverOffset") {
        didSet { UserDefaults.standard.set(serverOffset, forKey: "serverOffset") }
    }

    var favorites: Set<Int> = Set(UserDefaults.standard.array(forKey: "favorites") as? [Int] ?? []) {
        didSet { UserDefaults.standard.set(Array(favorites), forKey: "favorites") }
    }

    init() {
        config = XtreamConfig.load()
    }

    var client: XtreamClient? { config.map { XtreamClient(config: $0) } }

    // MARK: Dérivés

    var selectedStream: LiveStream? {
        guard let id = selectedStreamID else { return nil }
        return streams.first { $0.streamID == id }
    }

    private var categoryNames: [String: String] {
        Dictionary(categories.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
    }

    func categoryName(for stream: LiveStream) -> String? {
        stream.categoryID.flatMap { categoryNames[$0] }
    }

    func count(for item: SidebarItem) -> Int {
        streams(for: item).count
    }

    func streams(for item: SidebarItem?) -> [LiveStream] {
        switch item ?? .all {
        case .all: return streams
        case .catchup: return streams.filter(\.hasArchive)
        case .favorites: return streams.filter { favorites.contains($0.streamID) }
        case .category(let id): return streams.filter { $0.categoryID == id }
        }
    }

    var visibleStreams: [LiveStream] {
        let base = streams(for: sidebarSelection)
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return base }
        return base.filter { $0.name.localizedStandardContains(q) }
    }

    /// Catégories qui contiennent au moins une chaîne avec catchup, en premier.
    var sortedCategories: [LiveCategory] {
        let withArchive = Set(streams.filter(\.hasArchive).compactMap(\.categoryID))
        return categories.filter { cat in streams.contains { $0.categoryID == cat.id } }
            .sorted { a, b in
                let ra = withArchive.contains(a.id), rb = withArchive.contains(b.id)
                return ra != rb ? ra : false
            }
    }

    func categoryHasArchive(_ cat: LiveCategory) -> Bool {
        streams.contains { $0.categoryID == cat.id && $0.hasArchive }
    }

    // MARK: Actions

    func toggleFavorite(_ stream: LiveStream) {
        if favorites.contains(stream.streamID) { favorites.remove(stream.streamID) } else { favorites.insert(stream.streamID) }
    }

    func saveConfig(_ new: XtreamConfig) throws {
        var cfg = new
        cfg.normalize()
        try cfg.save()
        let serverChanged = cfg.baseURL != config?.baseURL || cfg.username != config?.username || cfg.password != config?.password
        config = cfg
        if serverChanged {
            streams = []
            categories = []
            epg = [:]
            epgState = [:]
            loadState = .idle
        }
    }

    func loadChannels(force: Bool = false) async {
        guard let client else { return }
        if loadState == .loading { return }
        if !force, loadState == .loaded { return }
        loadState = .loading
        do {
            async let cats = client.liveCategories()
            async let list = client.liveStreams()
            let (c, s) = try await (cats, list)
            categories = c
            streams = s
            if force { epg = [:]; epgState = [:] }
            loadState = .loaded
            if sidebarSelection == .catchup, !s.contains(where: \.hasArchive) { sidebarSelection = .all }
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    func loadEPG(for stream: LiveStream, force: Bool = false) async {
        guard let client else { return }
        if !force, epg[stream.streamID] != nil { return }
        epgState[stream.streamID] = .loading
        do {
            let list = try await client.epg(streamID: stream.streamID)
            epg[stream.streamID] = list
            epgState[stream.streamID] = .loaded
            // Décalage le plus fréquent dans la grille.
            let offsets = list.compactMap(\.serverOffset)
            if let mode = Dictionary(grouping: offsets, by: { $0 }).max(by: { $0.value.count < $1.value.count })?.key {
                serverOffset = mode
            }
        } catch {
            epgState[stream.streamID] = .failed(error.localizedDescription)
        }
    }
}
