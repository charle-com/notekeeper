import AppKit
import SwiftUI

extension Notification.Name { static let qaCommand = Notification.Name("nk.qa") }

/// Scénario de recette sans humain : captures PNG de chaque écran avec les moteurs factices,
/// puis sortie. Activé par `NOTEKEEPER_QA_DIR=<dossier>`.
@MainActor
final class QARunner {
    let model: AppModel
    let dir: URL
    init(model: AppModel, directory: URL) { self.model = model; self.dir = directory }

    func run() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        model.showWelcome = false
        var log: [String] = []
        func snap(_ name: String, after: Double, _ then: (() -> Void)? = nil) {
            DispatchQueue.main.asyncAfter(deadline: .now() + after) { [self] in
                if let w = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 600 }) {
                    w.makeKeyAndOrderFront(nil)
                    if let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                        v.cacheDisplay(in: v.bounds, to: rep)
                        if let png = rep.representation(using: .png, properties: [:]) {
                            try? png.write(to: dir.appendingPathComponent("\(name).png"))
                            log.append("\(name): \(Int(v.bounds.width))x\(Int(v.bounds.height)) visible=\(w.isVisible) occluded=\(!w.occlusionState.contains(.visible))")
                        }
                    }
                }
                try? log.joined(separator: "\n").write(to: dir.appendingPathComponent("log.txt"), atomically: true, encoding: .utf8)
                then?()
            }
        }
        if AppSettings.qaReal { runReal(snap: snap); return }
        snap("01-vide", after: 0.5) { self.model.startMeeting(source: "Google Meet (Chrome)") }
        snap("02-live", after: 14)
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { self.model.catchUp() }
        snap("03-rattrapage", after: 19) { Task { await self.model.stopMeeting() } }
        snap("04-transcript", after: 27) { NotificationCenter.default.post(name: .qaCommand, object: "tab:summary") }
        snap("05-resume", after: 29) {
            NotificationCenter.default.post(name: .qaCommand, object: "tab:transcript")
            NotificationCenter.default.post(name: .qaCommand, object: "ask:show")
            self.model.ask("Qui envoie l'attendu ShippingBo ?", allMeetings: false)
        }
        snap("06-demander", after: 34) {
            self.model.searchText = "camion"
        }
        snap("07-recherche", after: 36) { NSApp.terminate(nil) }
    }

    /// Recette réelle : attend que Whisper soit prêt, enregistre `NOTEKEEPER_QA_SECONDS` secondes (défaut 45)
    /// pendant qu'un script externe joue de la parole, puis attend le post-traitement complet.
    private func runReal(snap: @escaping (String, Double, (() -> Void)?) -> Void) {
        let seconds = Double(ProcessInfo.processInfo.environment["NOTEKEEPER_QA_SECONDS"] ?? "") ?? 45
        var waited = 0.0
        func whenReady(_ then: @escaping () -> Void) {
            if model.engineReady { then(); return }
            waited += 2
            if waited > 900 { try? "moteur jamais prêt : \(model.engineStatus)".write(to: dir.appendingPathComponent("error.txt"), atomically: true, encoding: .utf8); NSApp.terminate(nil) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { whenReady(then) }
        }
        whenReady { [self] in
            try? "ready".write(to: dir.appendingPathComponent("ready.txt"), atomically: true, encoding: .utf8)
            snap("r01-pret", 0.5) { self.model.startMeeting(source: "Recette") }
            snap("r02-live", seconds * 0.6, nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds * 0.7) { self.model.catchUp() }
            snap("r03-rattrapage", seconds * 0.7 + 12) { Task { await self.model.stopMeeting() } }
            var polls = 0
            @MainActor func waitReady() {
                polls += 1
                let m = self.model.meetings.first
                let done = m.map { $0.status == .ready || $0.status == .failed } ?? false
                if done || polls > 60 {
                    snap("r04-transcript", 1) { NotificationCenter.default.post(name: .qaCommand, object: "tab:summary") }
                    snap("r05-resume", 3) {
                        NotificationCenter.default.post(name: .qaCommand, object: "tab:transcript")
                        NotificationCenter.default.post(name: .qaCommand, object: "ask:show")
                        self.model.ask("Qu'est-ce qui a été décidé ?", allMeetings: false)
                    }
                    snap("r06-demander", 40) { NSApp.terminate(nil) }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { Task { @MainActor in waitReady() } }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds * 0.7 + 16) { Task { @MainActor in waitReady() } }
        }
    }
}
