import SwiftUI

struct ChannelListView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        let items = store.visibleStreams

        List(items, selection: $store.selectedStreamID) { stream in
            ChannelRow(stream: stream,
                       category: showCategory ? store.categoryName(for: stream) : nil,
                       isFavorite: store.favorites.contains(stream.streamID))
                .tag(stream.streamID)
                .contextMenu {
                    Button(store.favorites.contains(stream.streamID) ? "Retirer des favoris" : "Ajouter aux favoris") {
                        store.toggleFavorite(stream)
                    }
                }
        }
        .listStyle(.inset)
        .navigationTitle(title)
        .navigationSubtitle("\(items.count) chaîne\(items.count > 1 ? "s" : "")")
        .overlay {
            if store.loadState == .loaded && items.isEmpty {
                if !store.searchText.isEmpty {
                    ContentUnavailableView.search(text: store.searchText)
                } else if store.sidebarSelection == .favorites {
                    ContentUnavailableView("Aucun favori", systemImage: "star",
                                           description: Text("Clic droit sur une chaîne pour l'ajouter aux favoris."))
                } else {
                    ContentUnavailableView("Aucune chaîne", systemImage: "tv.slash")
                }
            }
        }
    }

    private var showCategory: Bool {
        if case .some(.category) = store.sidebarSelection { return false }
        return true
    }

    private var title: String {
        switch store.sidebarSelection ?? .all {
        case .all: return "Toutes les chaînes"
        case .catchup: return "Avec replay"
        case .favorites: return "Favoris"
        case .category(let id): return store.categories.first { $0.id == id }?.name ?? "Catégorie"
        }
    }
}

struct ChannelRow: View {
    let stream: LiveStream
    let category: String?
    let isFavorite: Bool

    var body: some View {
        HStack(spacing: 10) {
            ChannelLogo(url: stream.icon, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(stream.name).lineLimit(1)
                    if isFavorite {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                    }
                }
                if let category {
                    Text(category).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if stream.hasArchive {
                Text(stream.archiveDays > 0 ? "\(stream.archiveDays) j" : "replay")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    .foregroundStyle(Color.accentColor)
                    .help("Replay disponible sur \(stream.archiveDays) jours")
            }
        }
        .padding(.vertical, 2)
    }
}

struct ChannelLogo: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFit().padding(size * 0.08)
            } else {
                Image(systemName: "tv").foregroundStyle(.tertiary).font(.system(size: size * 0.4))
            }
        }
        .frame(width: size, height: size)
        .background(RoundedRectangle(cornerRadius: size * 0.22).fill(Color.primary.opacity(0.06)))
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
    }
}
