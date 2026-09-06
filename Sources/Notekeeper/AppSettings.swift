import Foundation

/// Réglages de l'app (UserDefaults). Les clés `llm.*` sont partagées avec `LLMConfig` (NotekeeperCore).
enum AppSettings {
    static let d = UserDefaults.standard

    static var userName: String {
        get { d.string(forKey: "llm.userName").flatMap { $0.isEmpty ? nil : $0 } ?? "Moi" }
        set { d.set(newValue, forKey: "llm.userName") }
    }
    static var language: String {
        get { d.string(forKey: "language") ?? "fr" }
        set { d.set(newValue, forKey: "language") }
    }
    static var exportFolder: URL {
        get {
            if let p = d.string(forKey: "exportFolder"), !p.isEmpty { return URL(fileURLWithPath: p) }
            return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Notekeeper", isDirectory: true)
        }
        set { d.set(newValue.path, forKey: "exportFolder") }
    }
    static var autoExport: Bool {
        get { d.object(forKey: "autoExport") == nil ? true : d.bool(forKey: "autoExport") }
        set { d.set(newValue, forKey: "autoExport") }
    }
    static var keepAudio: Bool {
        get { d.object(forKey: "keepAudio") == nil ? true : d.bool(forKey: "keepAudio") }
        set { d.set(newValue, forKey: "keepAudio") }
    }
    /// Fenêtre du « Qu'est-ce que j'ai raté ? », en secondes.
    static var catchUpWindow: Int {
        get { let v = d.integer(forKey: "catchUpWindow"); return v == 0 ? 180 : v }
        set { d.set(newValue, forKey: "catchUpWindow") }
    }
    static var askBeforeRecordingCalls: Bool {
        get { d.object(forKey: "askOnCall") == nil ? true : d.bool(forKey: "askOnCall") }
        set { d.set(newValue, forKey: "askOnCall") }
    }
    static var onboardingDone: Bool {
        get { d.bool(forKey: "onboardingDone") }
        set { d.set(newValue, forKey: "onboardingDone") }
    }
    /// Recette avec les vrais moteurs (micro, tap système, Whisper, LLM) : `NOTEKEEPER_QA_REAL=1`.
    static var qaReal: Bool { ProcessInfo.processInfo.environment["NOTEKEEPER_QA_REAL"] == "1" }
    static var useMocks: Bool { ProcessInfo.processInfo.environment["NOTEKEEPER_MOCK"] == "1" }
    static var qaDirectory: URL? {
        ProcessInfo.processInfo.environment["NOTEKEEPER_QA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
}

import AppKit
import NotekeeperAudio

extension AudioPermissions {
    /// Sonde le tap système en jouant un son court : macOS livre du silence aussi bien quand rien ne joue
    /// que quand l'autorisation est refusée, donc un test muet ne prouve rien.
    static func probeWithSound() async -> Bool {
        let sound = NSSound(named: "Glass")
        sound?.volume = 0.4
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { sound?.play() }
        let verdict = await probeSystemAudio(duration: 1.5)
        return verdict == .granted
    }
}
