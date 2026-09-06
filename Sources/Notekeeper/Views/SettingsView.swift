import SwiftUI
import AVFoundation
import NotekeeperCore
import NotekeeperAudio

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("Général", systemImage: "gear") }
            AISettings().tabItem { Label("IA", systemImage: "sparkles") }
            DictionarySettings().tabItem { Label("Dictionnaire", systemImage: "character.book.closed") }
            MCPSettings().tabItem { Label("MCP", systemImage: "point.3.connected.trianglepath.dotted") }
            PermissionsSettings().tabItem { Label("Autorisations", systemImage: "lock.shield") }
        }
        .frame(width: 560, height: 420)
    }
}

struct GeneralSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var userName = AppSettings.userName
    @State private var language = AppSettings.language
    @State private var exportFolder = AppSettings.exportFolder
    @State private var autoExport = AppSettings.autoExport
    @State private var keepAudio = AppSettings.keepAudio
    @State private var catchUp = AppSettings.catchUpWindow
    @State private var askOnCall = AppSettings.askBeforeRecordingCalls

    var body: some View {
        Form {
            TextField("Ton nom (affiché sur ta piste)", text: $userName).onChange(of: userName) { AppSettings.userName = $0 }
            Picker("Langue des réunions", selection: $language) {
                Text("Français").tag("fr"); Text("Anglais").tag("en"); Text("Détection automatique").tag("auto")
            }.onChange(of: language) { AppSettings.language = $0 }
            Picker("Fenêtre « Qu'est-ce que j'ai raté ? »", selection: $catchUp) {
                Text("2 minutes").tag(120); Text("3 minutes").tag(180); Text("5 minutes").tag(300); Text("10 minutes").tag(600)
            }.onChange(of: catchUp) { AppSettings.catchUpWindow = $0 }
            Toggle("Proposer d'enregistrer quand un appel est détecté", isOn: $askOnCall).onChange(of: askOnCall) { AppSettings.askBeforeRecordingCalls = $0 }
            Divider()
            LabeledContent("Dossier d'export markdown") {
                HStack {
                    Text(exportFolder.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Button("Choisir…") {
                        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
                        if p.runModal() == .OK, let u = p.url { exportFolder = u; AppSettings.exportFolder = u }
                    }
                }
            }
            Toggle("Exporter automatiquement chaque réunion terminée", isOn: $autoExport).onChange(of: autoExport) { AppSettings.autoExport = $0 }
            Toggle("Conserver l'audio après traitement", isOn: $keepAudio).onChange(of: keepAudio) { AppSettings.keepAudio = $0 }
            Text("L'audio est stocké dans ~/Library/Application Support/Notekeeper/audio. Le désactiver supprime les WAV une fois le transcript final produit.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

struct AISettings: View {
    @EnvironmentObject var model: AppModel
    private let d = UserDefaults.standard
    @State private var provider = UserDefaults.standard.string(forKey: "llm.provider") ?? "gemini"
    @State private var geminiModel = UserDefaults.standard.string(forKey: "llm.geminiModel") ?? "gemini-3.1-pro-preview"
    @State private var ollamaModel = UserDefaults.standard.string(forKey: "llm.ollamaModel") ?? "qwen3:8b"
    @State private var ollamaURL = UserDefaults.standard.string(forKey: "llm.ollamaURL") ?? "http://127.0.0.1:11434"
    @State private var apiKey = ""
    @State private var keySaved = false

    var body: some View {
        Form {
            Picker("Fournisseur", selection: $provider) {
                Text("Gemini (Google, cloud)").tag("gemini"); Text("Ollama (local)").tag("ollama")
            }.onChange(of: provider) { d.set($0, forKey: "llm.provider"); rebuild() }
            Text("La transcription reste toujours locale (Whisper). Le fournisseur ne sert qu'aux noms, résumés et questions.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if provider == "gemini" {
                TextField("Modèle", text: $geminiModel).onChange(of: geminiModel) { d.set($0, forKey: "llm.geminiModel"); rebuild() }
                SecureField("Clé API Gemini", text: $apiKey)
                HStack {
                    Button("Enregistrer la clé") { try? Keychain.write(apiKey, account: "gemini"); keySaved = true; rebuild() }.disabled(apiKey.isEmpty)
                    if keySaved || (Keychain.read(account: "gemini") ?? "").isEmpty == false {
                        Label("Clé enregistrée dans le trousseau", systemImage: "checkmark.circle").foregroundStyle(NK.ok).font(.system(size: 12))
                    }
                    Spacer()
                    Link("Obtenir une clé", destination: URL(string: "https://aistudio.google.com/apikey")!).font(.system(size: 12))
                }
            } else {
                TextField("Modèle Ollama", text: $ollamaModel).onChange(of: ollamaModel) { d.set($0, forKey: "llm.ollamaModel"); rebuild() }
                TextField("URL du serveur", text: $ollamaURL).onChange(of: ollamaURL) { d.set($0, forKey: "llm.ollamaURL"); rebuild() }
                Text("Installe Ollama puis `ollama pull \(ollamaModel)`. Sur 16 Go, un modèle 8B tient ; les résumés seront moins fins qu'avec Gemini.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { keySaved = !(Keychain.read(account: "gemini") ?? "").isEmpty }
    }

    private func rebuild() {
        model.assistant = Assistant(llm: LLMConfig.makeClient(), store: model.store, userName: AppSettings.userName)
    }
}

struct DictionarySettings: View {
    @EnvironmentObject var model: AppModel
    @State private var terms: [(term: String, note: String?)] = []
    @State private var newTerm = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Noms propres, marques, jargon : ils guident Whisper et l'identification des locuteurs.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            List {
                ForEach(terms, id: \.term) { t in
                    HStack {
                        Text(t.term)
                        Spacer()
                        Button { try? model.store.removeDictionary(term: t.term); reload() } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                TextField("Ajouter un terme (ex. GreenLog, Kheops, Alexander)", text: $newTerm).textFieldStyle(.roundedBorder).onSubmit(add)
                Button("Ajouter", action: add).disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .onAppear(perform: reload)
    }

    private func add() {
        let t = newTerm.trimmingCharacters(in: .whitespaces); guard !t.isEmpty else { return }
        try? model.store.addDictionary(term: t); newTerm = ""; reload()
    }
    private func reload() { terms = (try? model.store.dictionary()) ?? [] }
}

struct MCPSettings: View {
    private var binary: String { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/notekeeper-mcp").path }
    private var command: String { "claude mcp add notekeeper \"\(binary)\"" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tes réunions deviennent du contexte pour Claude Code, Cursor ou tout client MCP : recherche, transcripts, résumés, notes.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            GroupBox("Claude Code") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(command).font(NK.mono(11)).textSelection(.enabled)
                    Button("Copier la commande") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string) }.controlSize(.small)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
            GroupBox("Configuration JSON (Cursor, Claude Desktop)") {
                Text("{\n  \"mcpServers\": {\n    \"notekeeper\": { \"command\": \"\(binary)\" }\n  }\n}")
                    .font(NK.mono(11)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
            Text("Outils exposés : list_meetings, get_meeting, get_transcript, search_meetings, add_note, rename_speaker.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(16)
    }
}

struct PermissionsSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var mic = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var systemAudio: Bool? = nil
    @State private var calendar = false
    @State private var checking = false

    var body: some View {
        Form {
            row("Microphone", ok: mic == .authorized, detail: mic == .authorized ? "Autorisé" : "Nécessaire pour ta voix") {
                if mic == .notDetermined { AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { mic = AVCaptureDevice.authorizationStatus(for: .audio) } } }
                else { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!) }
            }
            row("Enregistrement audio système", ok: systemAudio ?? false,
                detail: checking ? "Vérification…" : (systemAudio == nil ? "Non vérifié" : (systemAudio! ? "Autorisé" : "Nécessaire pour entendre les autres participants"))) {
                checking = true
                Task { let ok = await AudioPermissions.probeWithSound(); systemAudio = ok; checking = false
                    if !ok { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!) } }
            }
            row("Calendrier", ok: calendar, detail: calendar ? "Autorisé" : "Optionnel : titres et invités des réunions") {
                Task { calendar = await model.calendar.requestAccess() }
            }
            Text("Rappel : préviens toujours les participants avant d'enregistrer. Notekeeper n'invite aucun bot et ne notifie personne à ta place.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .onAppear { calendar = model.calendar.authorized }
    }

    private func row(_ title: String, ok: Bool, detail: String, action: @escaping () -> Void) -> some View {
        LabeledContent {
            HStack {
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                Button(ok ? "Vérifier" : "Autoriser", action: action).controlSize(.small)
            }
        } label: {
            Label(title, systemImage: ok ? "checkmark.circle.fill" : "circle").foregroundStyle(ok ? NK.ok : .primary)
        }
    }
}
