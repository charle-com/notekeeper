import Foundation
import NotekeeperAudio
import NotekeeperCore

/// Test de bout en bout du module de capture :
///   notekeeper-audiotest <dossier> [secondes] [--probe]
/// Enregistre N secondes (8 par défaut) des deux pistes dans <dossier>/mic.wav et
/// <dossier>/system.wav, affiche chaque seconde le RMS des deux pistes et l'app détectée, puis
/// la durée réelle des WAV. `--probe` lance d'abord le test d'autorisation audio système.

func usage() -> Never {
    FileHandle.standardError.write(Data("usage : notekeeper-audiotest <dossier> [secondes] [--probe]\n".utf8))
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
let probe = args.contains("--probe")
args.removeAll { $0 == "--probe" }
guard let folderArg = args.first else { usage() }
let seconds = args.count > 1 ? (Double(args[1]) ?? 8) : 8
let folder = URL(fileURLWithPath: folderArg)
try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let micURL = folder.appendingPathComponent("mic.wav")
let sysURL = folder.appendingPathComponent("system.wav")

func out(_ s: String) { print(s); fflush(stdout) }

out("micro : \(AudioPermissions.describe(AudioPermissions.microphoneStatus))")
if AudioPermissions.microphoneStatus == .notDetermined {
    out("  (la boîte d'autorisation micro va s'afficher ; sans réponse, ce test attend)")
}

if probe {
    let verdict = await AudioPermissions.probeSystemAudio(duration: 1.0)
    out(verdict.summary)
    if case .denied = verdict {
        out("  à cliquer : \(AudioPermissions.systemAudioSettingsURL.absoluteString)")
    }
}

// Accumulateurs RMS par seconde, alimentés par onSamples (file série de la session).
final class Stats: @unchecked Sendable {
    private let q = DispatchQueue(label: "audiotest.stats")
    private var sumSq: [Track: Double] = [:]
    private var count: [Track: Int] = [:]
    private var lastTime: [Track: TimeInterval] = [:]
    func add(_ track: Track, _ samples: [Float], _ time: TimeInterval) {
        var s: Double = 0
        for v in samples { s += Double(v * v) }
        q.sync { sumSq[track, default: 0] += s; count[track, default: 0] += samples.count; lastTime[track] = time }
    }
    /// RMS de la fenêtre écoulée et dernier temps livré, puis remise à zéro de la fenêtre.
    func flush(_ track: Track) -> (rms: Double, time: TimeInterval) {
        q.sync {
            let c = count[track, default: 0]
            let r = c > 0 ? (sumSq[track, default: 0] / Double(c)).squareRoot() : 0
            sumSq[track] = 0; count[track] = 0
            return (r, lastTime[track] ?? -1)
        }
    }
}
let stats = Stats()

let tapOptions = SystemTapOptions.fromEnvironment()
let session = CaptureSession(tapOptions: tapOptions)
// Cadence et amplitude des niveaux publiés (main thread, ~20 Hz attendus).
var levelCount = 0
var levelMax: (mic: Float, system: Float) = (0, 0)
session.onLevels = { m, s in
    levelCount += 1
    levelMax = (max(levelMax.mic, m), max(levelMax.system, s))
}
let detector = ProcessCallDetector()
var detectedApp: String? = nil
detector.onChange = { app in detectedApp = app }
detector.start()

do {
    try await session.start(micWAV: micURL, systemWAV: sysURL) { track, samples, time in
        stats.add(track, samples, time)
    }
} catch {
    out("ERREUR au démarrage : \(error)")
    out("  micro : \(AudioPermissions.microphoneSettingsURL.absoluteString)")
    exit(1)
}

out("micro : \(session.micDeviceName)")
out("audio système : \(session.isSystemAudioActive ? "actif (sortie \(session.systemOutputName))" : "INACTIF")")
if let w = session.lastWarning {
    out("avertissement : \(w)")
    out("  à cliquer : \(AudioPermissions.systemAudioSettingsURL.absoluteString)")
}
out("enregistrement \(Int(seconds)) s dans \(folder.path)")
out(String(format: "%4@  %8@  %8@  %7@  %7@  %@", "t", "rms mic", "rms sys", "t mic", "t sys", "app détectée"))

let startedAt = Date()
// Le main actor reste libre pendant le sleep : les callbacks main thread (niveaux, onChange)
// s'exécutent entre deux ticks.
for tick in 1...max(1, Int(seconds.rounded())) {
    try? await Task.sleep(nanoseconds: 1_000_000_000)
    let m = stats.flush(.mic)
    let s = stats.flush(.system)
    out(String(format: "%3ds  %8.4f  %8.4f  %7.2f  %7.2f  %@", tick, m.rms, s.rms, m.time, s.time, detectedApp ?? "aucune"))
}

let elapsed = Date().timeIntervalSince(startedAt)
await session.stop()
detector.stop()
out(String(format: "niveaux : %d publications en %.1f s (%.1f Hz), max micro %.2f, max système %.2f",
           levelCount, elapsed, Double(levelCount) / elapsed, levelMax.mic, levelMax.system))

for (label, url) in [("mic.wav", micURL), ("system.wav", sysURL)] {
    let d = WAVWriter.duration(of: url).map { String(format: "%.2f s", $0) } ?? "illisible"
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    out("\(label) : \(d), \(size) octets")
}
if let w = session.lastWarning { out("dernier avertissement : \(w)") }
out("app détectée en fin de test : \(detector.currentApp ?? "aucune")")
