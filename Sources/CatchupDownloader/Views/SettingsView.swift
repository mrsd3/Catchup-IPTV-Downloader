import AppKit
import SwiftUI

/// Champs serveur partagés entre l'accueil et les réglages.
struct ServerFields: View {
    @Binding var draft: XtreamConfig

    var body: some View {
        TextField("Serveur", text: $draft.host, prompt: Text("iptv.exemple.com"))
        TextField("Port", text: $draft.port, prompt: Text("8080"))
        TextField("Identifiant", text: $draft.username)
            .textContentType(.username)
        SecureField("Mot de passe", text: $draft.password)
            .textContentType(.password)
    }
}

struct OnboardingView: View {
    @Environment(AppStore.self) private var store
    @State private var draft = XtreamConfig()
    @State private var testing = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "play.tv.fill")
                .font(.system(size: 54))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
            VStack(spacing: 6) {
                Text("Catchup").font(.largeTitle.weight(.bold))
                Text("Récupérez les replays de votre abonnement IPTV (Xtream Codes).")
                    .foregroundStyle(.secondary)
            }

            Form {
                ServerFields(draft: $draft)
            }
            .formStyle(.grouped)
            .frame(width: 420)
            .fixedSize(horizontal: false, vertical: true)
            .scrollDisabled(true)

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .frame(maxWidth: 420)
            }

            Button {
                Task { await connect() }
            } label: {
                if testing {
                    ProgressView().controlSize(.small).frame(width: 120)
                } else {
                    Text("Se connecter").frame(width: 120)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(testing || draft.host.isEmpty || draft.username.isEmpty || draft.password.isEmpty)

            Text("Les identifiants sont enregistrés dans ~/.catchup_config.json, comme pour la version en ligne de commande.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func connect() async {
        testing = true
        error = nil
        defer { testing = false }
        var cfg = draft
        cfg.normalize()
        do {
            try await XtreamClient(config: cfg).authenticate()
            try store.saveConfig(cfg)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("Général", systemImage: "gearshape") }
            ServerSettings()
                .tabItem { Label("Serveur", systemImage: "server.rack") }
            DownloadSettings()
                .tabItem { Label("Téléchargement", systemImage: "arrow.down.circle") }
        }
        .frame(width: 520)
    }
}

private struct GeneralSettings: View {
    /// "system" ou un code de langue. Appliqué via AppleLanguages, lu par macOS au lancement de l'app.
    @AppStorage("appLanguage") private var language = "system"
    @State private var changed = false

    var body: some View {
        Form {
            Section {
                Picker("Langue", selection: $language) {
                    Text("Langue du système").tag("system")
                    Text(verbatim: "Français").tag("fr")
                    Text(verbatim: "English").tag("en")
                }
            } footer: {
                if changed {
                    HStack {
                        Text("La nouvelle langue sera utilisée au prochain lancement.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Relancer maintenant") { relaunch() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: language) { _, new in
            if new == "system" {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.set([new], forKey: "AppleLanguages")
            }
            changed = true
        }
    }

    private func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

private struct ServerSettings: View {
    @Environment(AppStore.self) private var store
    @State private var draft = XtreamConfig()
    @State private var status: (ok: Bool, text: String)?
    @State private var testing = false

    var body: some View {
        Form {
            Section {
                ServerFields(draft: $draft)
            }

            Section {
                Picker("Format d'URL replay", selection: $draft.urlFormat) {
                    ForEach(XtreamClient.formatDescriptions, id: \.0) { Text($0.1).tag($0.0) }
                }
                LabeledContent("Décalage horaire serveur") {
                    Text(offsetLabel).monospacedDigit()
                }
            } footer: {
                Text("Si les téléchargements échouent ou sont décalés, essayez un autre format : chaque fournisseur a le sien. Le décalage horaire est détecté automatiquement à partir du guide des programmes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    if let status {
                        Label(status.text, systemImage: status.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(status.ok ? Color.green : Color.red)
                            .lineLimit(2)
                    }
                    Spacer()
                    Button("Tester") { Task { await test() } }
                        .disabled(testing)
                    Button("Enregistrer") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(draft == store.config)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { if let cfg = store.config { draft = cfg } }
    }

    private var offsetLabel: String {
        let h = store.serverOffset / 3600
        if h == 0 { return String(localized: "aucun") }
        return String(format: "%+.2g h", locale: DateFormats.appLocale, h)
    }

    private func test() async {
        testing = true
        defer { testing = false }
        var cfg = draft
        cfg.normalize()
        do {
            try await XtreamClient(config: cfg).authenticate()
            status = (true, String(localized: "Connexion réussie"))
        } catch {
            status = (false, error.localizedDescription)
        }
    }

    private func save() {
        var cfg = draft
        // Le dossier et FFmpeg se règlent dans l'autre onglet : on garde leurs valeurs actuelles.
        cfg.outputDir = store.config?.outputDir
        cfg.ffmpegPath = store.config?.ffmpegPath
        do {
            try store.saveConfig(cfg)
            if let cfg = store.config { draft = cfg }
            status = (true, String(localized: "Réglages enregistrés"))
            Task { await store.loadChannels() }
        } catch {
            status = (false, error.localizedDescription)
        }
    }
}

private struct DownloadSettings: View {
    @Environment(AppStore.self) private var store
    @AppStorage("marginBefore") private var marginBefore = 2
    @AppStorage("marginAfter") private var marginAfter = 5

    var body: some View {
        Form {
            Section("Destination") {
                LabeledContent("Dossier") {
                    HStack {
                        Text(store.config?.outputDirectory.path(percentEncoded: false) ?? "—")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choisir…") { chooseFolder() }
                    }
                }
            }

            Section("Marges par défaut (mode Programmes)") {
                Stepper("Avant le début : \(marginBefore) min", value: $marginBefore, in: 0...30)
                Stepper("Après la fin : \(marginAfter) min", value: $marginAfter, in: 0...60)
            }

            Section("FFmpeg") {
                if let found = DownloadManager.findFFmpeg(custom: store.config?.ffmpegPath) {
                    LabeledContent("Utilisé") {
                        Text(found).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                } else {
                    Label("FFmpeg introuvable — installez-le avec « brew install ffmpeg ».", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Button("Choisir un exécutable…") { chooseFFmpeg() }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = store.config?.outputDirectory
        guard panel.runModal() == .OK, let url = panel.url, var cfg = store.config else { return }
        cfg.outputDir = url.path
        try? store.saveConfig(cfg)
    }

    private func chooseFFmpeg() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        guard panel.runModal() == .OK, let url = panel.url, var cfg = store.config else { return }
        cfg.ffmpegPath = url.path
        try? store.saveConfig(cfg)
    }
}
