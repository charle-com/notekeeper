import Foundation
import AVFoundation

/// Autorisations nécessaires à la capture : micro (TCC classique) et « Enregistrement audio
/// système » (TCC `AudioCapture`, sans API publique de consultation : on le teste par un tap
/// d'essai).
public enum AudioPermissions {

    /// Réglages Système > Confidentialité > Enregistrement audio système.
    public static let systemAudioSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
    /// Réglages Système > Confidentialité > Microphone.
    public static let microphoneSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!

    // MARK: Micro

    public static var microphoneStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// Demande l'accès au micro (affiche la boîte système si jamais posée). Vrai si accordé.
    public static func requestMicrophone() async -> Bool {
        switch microphoneStatus {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    public static func describe(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "autorisé"
        case .denied: return "refusé"
        case .restricted: return "restreint"
        case .notDetermined: return "jamais demandé"
        @unknown default: return "inconnu"
        }
    }

    // MARK: Audio système

    public enum SystemAudioVerdict: Equatable {
        /// Le tap a livré des échantillons non nuls : autorisation acquise.
        case granted
        /// La création du tap ou de l'agrégat a été refusée.
        case denied(String)
        /// Callbacks reçus mais uniquement du silence : rien ne jouait, ou autorisation refusée
        /// (macOS livre du silence dans ce cas). Relancer pendant qu'un son joue pour trancher.
        case silent
        /// Aucun callback pendant le test.
        case noData

        public var summary: String {
            switch self {
            case .granted: return "audio système : autorisé (données reçues)"
            case .denied(let why): return "audio système : refusé (\(why))"
            case .silent: return "audio système : indéterminé (silence seul : rien ne jouait, ou autorisation refusée)"
            case .noData: return "audio système : indéterminé (aucun callback)"
            }
        }
    }

    /// Tap d'essai d'une seconde (par défaut). Déclenche la boîte système la première fois.
    /// À appeler hors du main thread de préférence : bloque `duration`.
    public static func probeSystemAudio(duration: TimeInterval = 1.0) async -> SystemAudioVerdict {
        guard #available(macOS 14.2, *) else { return .denied("macOS 14.2 minimum") }
        return await withCheckedContinuation { (cont: CheckedContinuation<SystemAudioVerdict, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var options = SystemTapOptions.fromEnvironment()
                options.autoStart = false
                let tap = SystemAudioTap(options: options)
                do {
                    try tap.start()
                } catch {
                    cont.resume(returning: .denied(error.localizedDescription))
                    return
                }
                Thread.sleep(forTimeInterval: duration)
                let stats = tap.stats
                tap.stop()
                if stats.nonZeroSamples > 0 { cont.resume(returning: .granted) }
                else if stats.callbacks > 0 { cont.resume(returning: .silent) }
                else { cont.resume(returning: .noData) }
            }
        }
    }
}
