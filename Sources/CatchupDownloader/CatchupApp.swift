import AppKit
import SwiftUI

@main
struct CatchupApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = AppStore()
    @State private var downloads = DownloadManager()

    var body: some Scene {
        WindowGroup("Catchup") {
            RootView()
                .environment(store)
                .environment(downloads)
                // > somme des largeurs mini des 3 colonnes (200 + 260 + 360), avec de la marge pour les séparateurs.
                .frame(minWidth: 880, minHeight: 600)
                .background(WindowMinSize(size: NSSize(width: 880, height: 600)))
                .onAppear { appDelegate.downloads = downloads }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Chaînes") {
                Button("Actualiser la liste") {
                    Task { await store.loadChannels(force: true) }
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(store.config == nil)
            }
        }

        Settings {
            SettingsView()
                .environment(store)
                .environment(downloads)
        }
    }
}

/// Impose la taille mini directement à la NSWindow : le .frame(minWidth:) du contenu n'est pas
/// répercuté par NavigationSplitView, et la fenêtre pouvait être rétrécie au point d'écraser les colonnes.
/// Agrandit aussi une fenêtre restaurée plus petite que ce minimum.
struct WindowMinSize: NSViewRepresentable {
    let size: NSSize

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // Hors de la passe de mise en page en cours : la fenêtre n'est pas encore attachée ici.
        DispatchQueue.main.async { apply(to: view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private func apply(to window: NSWindow?) {
        guard let window else { return }
        window.contentMinSize = size

        let content = window.contentRect(forFrameRect: window.frame)
        guard content.width < size.width || content.height < size.height else { return }
        var target = content
        target.size.width = max(content.width, size.width)
        target.size.height = max(content.height, size.height)
        target.origin.y -= target.height - content.height  // garde le bord haut en place
        var frame = window.frameRect(forContentRect: target)
        if let visible = window.screen?.visibleFrame {
            if frame.maxX > visible.maxX { frame.origin.x = max(visible.minX, visible.maxX - frame.width) }
            if frame.minY < visible.minY { frame.origin.y = visible.minY }
        }
        window.setFrame(frame, display: true, animate: false)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var downloads: DownloadManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Nécessaire quand l'app est lancée via `swift run` (pas de bundle).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Notifier.requestAuthorization()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let downloads, downloads.activeCount > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Des téléchargements sont en cours"
        alert.informativeText = "Quitter les arrêtera. Les fichiers déjà commencés seront conservés jusqu'au point atteint."
        alert.addButton(withTitle: "Quitter")
        alert.addButton(withTitle: "Annuler")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        downloads.stopAll()
        // Laisse à ffmpeg le temps de finaliser les fichiers.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
