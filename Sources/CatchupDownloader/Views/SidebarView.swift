import SwiftUI

struct SidebarView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store

        List(selection: $store.sidebarSelection) {
            Section("Bibliothèque") {
                row(.catchup, "Avec replay", "clock.arrow.circlepath")
                row(.favorites, "Favoris", "star")
                row(.all, "Toutes les chaînes", "tv")
            }

            if !store.categories.isEmpty {
                Section("Catégories") {
                    ForEach(store.sortedCategories) { cat in
                        Label {
                            HStack {
                                Text(cat.name).lineLimit(1)
                                Spacer()
                                Text("\(store.count(for: .category(cat.id)))")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        } icon: {
                            Image(systemName: store.categoryHasArchive(cat) ? "folder.fill" : "folder")
                        }
                        .tag(SidebarItem.category(cat.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            switch store.loadState {
            case .loading where store.streams.isEmpty:
                ProgressView("Chargement des chaînes…")
            case .failed(let msg):
                ContentUnavailableView {
                    Label("Connexion impossible", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(msg)
                } actions: {
                    Button("Réessayer") { Task { await store.loadChannels(force: true) } }
                    SettingsLink { Text("Réglages…") }
                }
            default:
                EmptyView()
            }
        }
        .safeAreaInset(edge: .bottom) {
            if store.loadState == .loaded {
                HStack {
                    Text("\(store.streams.count) chaînes · \(store.count(for: .catchup)) avec replay")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        Task { await store.loadChannels(force: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Actualiser la liste (⌘R)")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }

    private func row(_ item: SidebarItem, _ title: String, _ icon: String) -> some View {
        Label {
            HStack {
                Text(title)
                Spacer()
                if store.loadState == .loaded {
                    Text("\(store.count(for: item))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        } icon: {
            Image(systemName: icon)
        }
        .tag(item)
    }
}
