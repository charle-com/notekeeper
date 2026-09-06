import Foundation
import AppKit
import CoreAudio

/// Détection d'un appel en cours par les objets process de CoreAudio : toutes les 2 s, liste
/// `kAudioHardwarePropertyProcessObjectList`, lit `kAudioProcessPropertyIsRunningInput` (le
/// process capture le micro) et `kAudioProcessPropertyBundleID`, et en déduit l'application.
/// Exclut notre bundle, notre pid et les process système. `onChange` sur le main thread,
/// seulement quand la valeur change.
public final class ProcessCallDetector: CallDetector, @unchecked Sendable {

    public var onChange: ((String?) -> Void)? {
        get { lock.withLock { _onChange } }
        set { lock.withLock { _onChange = newValue } }
    }
    public var currentApp: String? { lock.withLock { _currentApp } }

    public static let ownBundleID = "fr.charlesneveu.notekeeper"
    public static let interval: TimeInterval = 2

    /// Bundle ID (ou préfixe) -> nom affiché. L'ordre donne la priorité quand plusieurs process
    /// capturent le micro (Zoom devant un navigateur, un navigateur devant une app inconnue).
    public static let knownApps: [(bundle: String, name: String)] = [
        ("us.zoom.xos", "Zoom"),
        ("com.microsoft.teams2", "Teams"),
        ("com.microsoft.teams", "Teams"),
        ("com.apple.FaceTime", "FaceTime"),
        ("net.whatsapp.WhatsApp", "WhatsApp"),
        ("com.tinyspeck.slackmacgap", "Slack"),
        ("com.hnc.Discord", "Discord"),
        ("com.google.Chrome", "Google Meet (Chrome)"),
        ("com.apple.Safari", "Appel (Safari)"),
        ("org.mozilla.firefox", "Appel (Firefox)"),
        ("org.mozilla.plugincontainer", "Appel (Firefox)"),
        ("company.thebrowser.Browser", "Appel (Arc)"),
    ]

    public init() {}

    deinit { stop() }

    public func start() {
        lock.withLock {
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 0.2, repeating: Self.interval, leeway: .milliseconds(200))
            t.setEventHandler { [weak self] in self?.poll() }
            t.resume()
            timer = t
        }
    }

    public func stop() {
        lock.withLock {
            timer?.cancel()
            timer = nil
        }
    }

    // MARK: Interne

    private let lock = UnfairLock()
    private let queue = DispatchQueue(label: "fr.charlesneveu.notekeeper.calldetector", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var _onChange: ((String?) -> Void)?
    private var _currentApp: String?

    private func poll() {
        let detected = Self.detectCallApp()
        let changed = lock.withLock { () -> Bool in
            guard _currentApp != detected else { return false }
            _currentApp = detected
            return true
        }
        guard changed, let cb = onChange else { return }
        DispatchQueue.main.async { cb(detected) }
    }

    /// Un passage : l'app en appel la plus plausible, ou nil. Utilisable seule (test).
    public static func detectCallApp() -> String? {
        candidates().first?.name
    }

    /// Toutes les apps qui capturent le micro, triées par priorité (table connue d'abord).
    public static func candidates() -> [(name: String, bundle: String, pid: pid_t)] {
        let ownPID = getpid()
        let ownBundle = Bundle.main.bundleIdentifier
        var found: [(rank: Int, name: String, bundle: String, pid: pid_t)] = []
        for obj in CoreAudioProps.objectIDs(CoreAudioProps.system, kAudioHardwarePropertyProcessObjectList) {
            guard CoreAudioProps.uint32(obj, kAudioProcessPropertyIsRunningInput) == 1 else { continue }
            let pid = pid_t(CoreAudioProps.int32(obj, kAudioProcessPropertyPID) ?? 0)
            let bundle = CoreAudioProps.string(obj, kAudioProcessPropertyBundleID) ?? ""
            guard pid != ownPID, bundle != ownBundleID, bundle != ownBundle else { continue }
            guard let (rank, name) = classify(bundle: bundle, pid: pid) else { continue }
            found.append((rank, name, bundle, pid))
        }
        return found.sorted { $0.rank < $1.rank }.map { ($0.name, $0.bundle, $0.pid) }
    }

    /// Nom affiché et rang de priorité d'un process capturant le micro, nil s'il est à ignorer.
    static func classify(bundle: String, pid: pid_t) -> (Int, String)? {
        for (i, app) in knownApps.enumerated() where bundle == app.bundle || bundle.hasPrefix(app.bundle + ".") {
            return (i, app.name)
        }
        // Process sans bundle (outils en ligne de commande) : ignorés.
        guard !bundle.isEmpty else { return nil }
        let app = NSRunningApplication(processIdentifier: pid)
        // Process système Apple (coreaudiod, Siri, Centre de contrôle, dictée…) : tout `com.apple.*`
        // qui n'est pas une vraie application (icône dans le Dock). QuickTime ou Dictaphone passent.
        if bundle.hasPrefix("com.apple."), app?.activationPolicy != .regular { return nil }
        let name = app?.localizedName ?? bundle.split(separator: ".").last.map(String.init) ?? bundle
        return (knownApps.count, name)
    }
}
