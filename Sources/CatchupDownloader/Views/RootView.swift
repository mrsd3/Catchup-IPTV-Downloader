import SwiftUI

struct RootView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        if store.config == nil {
            OnboardingView()
        } else {
            MainView()
        }
    }
}

struct MainView: View {
    @Environment(AppStore.self) private var store
    @Environment(DownloadManager.self) private var downloads
    @State private var showDownloads = false
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        @Bindable var store = store

        NavigationSplitView(columnVisibility: $columns) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } content: {
            ChannelListView()
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 460)
        } detail: {
            Group {
                if let stream = store.selectedStream {
                    ChannelDetailView(stream: stream)
                        .id(stream.streamID)
                } else {
                    ContentUnavailableView("Choisissez une chaîne",
                                           systemImage: "tv",
                                           description: Text("Sélectionnez une chaîne pour voir ses programmes en replay."))
                }
            }
            .navigationSplitViewColumnWidth(min: 360, ideal: 520)
        }
        .searchable(text: $store.searchText, placement: .sidebar, prompt: "Rechercher une chaîne")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showDownloads.toggle()
                } label: {
                    Label("Téléchargements", systemImage: downloads.activeCount > 0 ? "arrow.down.circle.fill" : "arrow.down.circle")
                        .symbolEffect(.pulse, isActive: downloads.activeCount > 0)
                }
                .help("Téléchargements")
                // Bulle comme dans les navigateurs : ne touche pas à la mise en page de la fenêtre.
                .popover(isPresented: $showDownloads, arrowEdge: .bottom) {
                    DownloadsPanel()
                }
                .overlay(alignment: .topTrailing) {
                    if downloads.activeCount > 0 {
                        Text("\(downloads.activeCount)")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .background(Capsule().fill(.red))
                            .offset(x: 6, y: -4)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .task { await store.loadChannels() }
        .onChange(of: downloads.jobs.count) { old, new in
            // Comme un navigateur : la bulle s'ouvre quand un téléchargement est ajouté.
            if new > old, !showDownloads {
                DispatchQueue.main.async { showDownloads = true }
            }
        }
    }
}
