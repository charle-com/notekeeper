import SwiftUI
import UserNotifications
import NotekeeperCore
import NotekeeperAudio
import NotekeeperSpeech

@main
struct NotekeeperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model: AppModel = AppFactory.makeModel()

    var body: some Scene {
        WindowGroup("Notekeeper", id: "main") {
            MainWindow()
                .environmentObject(model)
                .frame(minWidth: 960, minHeight: 600)
                .onAppear { delegate.model = model }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(model.isRecording ? "Terminer la réunion" : "Enregistrer une réunion") {
                    if model.isRecording { Task { await model.stopMeeting() } } else { model.startMeeting() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Button("Exporter en markdown") { if let m = model.selectedMeeting { model.export(m) } }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(model.selectedMeeting == nil)
            }
            CommandGroup(after: .toolbar) {
                Button("Qu'est-ce que j'ai raté ?") { model.catchUp() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                    .disabled(!model.isRecording)
            }
        }
        .defaultSize(width: 1180, height: 740)

        MenuBarExtra {
            MenuBarMenu().environmentObject(model)
        } label: {
            Image(systemName: model.isRecording ? "record.circle.fill" : "text.bubble")
        }

        Settings {
            SettingsView().environmentObject(model)
        }
    }
}

enum AppFactory {
    @MainActor static func makeModel() -> AppModel {
        let store: Store
        let dbURL = ProcessInfo.processInfo.environment["NOTEKEEPER_DB"].map { URL(fileURLWithPath: $0) } ?? Store.defaultURL()
        do { store = try Store(url: dbURL) }
        catch { fatalError("Base introuvable : \(error)") }
        if AppSettings.useMocks || (AppSettings.qaDirectory != nil && !AppSettings.qaReal) {
            return AppModel(store: store, capture: MockCaptureEngine(), speech: MockSpeechEngine(),
                            calls: MockCallDetector(), assistant: MockAssistant(store: store))
        }
        let assistant = Assistant(llm: LLMConfig.makeClient(), store: store, userName: AppSettings.userName)
        return AppModel(store: store, capture: CaptureSession(), speech: WhisperSpeechEngine(),
                        calls: ProcessCallDetector(), assistant: assistant)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        if let dir = AppSettings.qaDirectory {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let model = self?.model else { return }
                QARunner(model: model, directory: dir).run()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.isRecording else { return .terminateNow }
        Task { @MainActor in await model.stopMeeting(); NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

struct MenuBarMenu: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let r = model.recording {
            Text("Enregistrement : \(TimeFormat.clock(r.elapsed))")
            Button("Qu'est-ce que j'ai raté ?") { model.catchUp(); openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
            Button("Terminer la réunion") { Task { await model.stopMeeting() } }
        } else {
            Button("Enregistrer une réunion") { model.startMeeting(); openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
            if let app = model.detectedCallApp { Text("Appel détecté : \(app)") }
        }
        Divider()
        Text(model.engineStatus).foregroundStyle(.secondary)
        Button("Ouvrir Notekeeper") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Divider()
        Button("Quitter") { NSApp.terminate(nil) }
    }
}
