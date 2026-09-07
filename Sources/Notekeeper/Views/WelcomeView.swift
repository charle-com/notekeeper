import SwiftUI
import AVFoundation
import NotekeeperAudio

/// Premier lancement : consentement, autorisations, chargement du modèle.
struct WelcomeView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = AppSettings.userName == "Moi" ? "" : AppSettings.userName
    @State private var mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var systemAudio = false
    @State private var checkingSystem = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Bienvenue dans Notekeeper").font(NK.title(24))
                Text("Transcription locale de tes réunions, qui a dit quoi, résumé, et une mémoire interrogeable.").foregroundStyle(.secondary)
            }
            TextField("Ton prénom et nom (pour étiqueter ta piste)", text: $name).textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 10) {
                step(done: mic, "Microphone", "Ta voix, transcrite sur ce Mac.") {
                    AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { mic = ok } }
                }
                step(done: systemAudio, "Audio système", "Les autres participants (Zoom, Meet, Teams, FaceTime…), sans bot dans l'appel.") {
                    checkingSystem = true
                    Task { systemAudio = await AudioPermissions.probeWithSound(); checkingSystem = false }
                }
                step(done: model.engineReady, "Transcription Whisper",
                     model.liveEnabled ? model.engineStatus : "Locale, lancée à la fin de chaque appel : rien ne tourne pendant.") {}
            }

            GroupBox {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "hand.raised").foregroundStyle(NK.warn)
                    Text("Préviens toujours les participants avant d'enregistrer. Notekeeper capture l'audio localement et n'envoie aucune notification à ta place ; la loi sur l'enregistrement varie selon le pays.")
                        .font(.system(size: 12))
                }.padding(4)
            }

            HStack {
                Spacer()
                Button("Commencer") {
                    if !name.trimmingCharacters(in: .whitespaces).isEmpty { AppSettings.userName = name.trimmingCharacters(in: .whitespaces) }
                    AppSettings.onboardingDone = true
                    dismiss()
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func step(done: Bool, _ title: String, _ detail: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle").foregroundStyle(done ? NK.ok : .secondary).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if !done, title != "Modèle Whisper" { Button("Autoriser", action: action).controlSize(.small) }
        }
    }
}
