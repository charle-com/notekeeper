# Module de capture audio (`NotekeeperAudio`)

Bibliothèque SwiftPM `Sources/NotekeeperAudio/` (dépend de `NotekeeperCore`), utilisée par l'app
`Notekeeper` et par l'outil de terrain `notekeeper-audiotest`. Les protocoles `CaptureEngine` et
`CallDetector` ont été déplacés dans `Sources/NotekeeperAudio/Contracts.swift` (en `public`) ;
`Sources/Notekeeper/Engine/Contracts.swift` ne garde que `SpeechEngine`.

## Implémenté

| Fichier | Rôle |
|---|---|
| `MicCapture.swift` | Micro par unité AUHAL (`kAudioUnitSubType_HALOutput`) en entrée seule : bus de sortie désactivé, device d'entrée fixé avant `AudioUnitInitialize`, la sortie n'est jamais touchée (pas de bascule AirPods en mains-libres). Thread IO sans allocation (pool de buffers préalloués), conversion 16 kHz mono par `AVAudioConverter` sur une file série. Suit le micro par défaut : s'il change ou disparaît en cours de capture, l'unité est recréée (débounce 400 ms). |
| `SystemAudioTap.swift` | Audio système par process tap : `CATapDescription(stereoGlobalTapButExcludeProcesses: [notre process])`, `muteBehavior = .unmuted`, `AudioHardwareCreateProcessTap`, agrégat privé (`private`, sous-device = sortie par défaut avec `master`, liste de taps `uid` + `drift`), `AudioDeviceCreateIOProcIDWithBlock` (file nil = thread IO, copie dans le pool) + `AudioDeviceStart`. Format lu par `kAudioTapPropertyFormat` (48 kHz stéréo Float32 entrelacé sur ce Mac). Index du buffer du tap dans l'AudioBufferList = nombre de flux d'entrée du sous-device. Écouteur `kAudioHardwarePropertyDefaultOutputDevice` : recrée tap + agrégat, le premier bloc suivant porte `discontinuity`. Destruction dans l'ordre inverse au stop. |
| `WAVWriter.swift` | WAV PCM 16 bits 16 kHz mono au fil de l'eau, en-tête réécrit toutes les 10 s d'audio et à la fermeture ; `appendSilence` pour le recalage ; `duration(of:)` lit l'en-tête. |
| `CaptureSession.swift` | `CaptureEngine`. Horloge commune = temps hôte de `start()` ; chaque piste est ancrée sur le temps hôte (`AudioTimeStamp.mHostTime`) de son premier callback, le WAV reçoit du silence jusque-là, puis avance au compte d'échantillons. Le temps livré à `onSamples` est la position dans le WAV : WAV, blocs et transcription partagent le même axe. Recalage par silence sur `discontinuity` ou si l'écart horloge/WAV dépasse 150 ms. Blocs livrés sur une file série interne, niveaux RMS lissés (courbe dB sur 50 dB, attaque instantanée, relâchement 25 %) sur le main thread à 20 Hz. Tap en échec = micro seul + `lastWarning`. Demande l'autorisation micro si jamais posée, lève une erreur si refusée. |
| `CallDetectorImpl.swift` | `ProcessCallDetector`. Toutes les 2 s : `kAudioHardwarePropertyProcessObjectList`, `kAudioProcessPropertyIsRunningInput`, `kAudioProcessPropertyBundleID`, `kAudioProcessPropertyPID`. Table des apps (Zoom, Teams x2, FaceTime, WhatsApp, Slack, Discord, Chrome, Safari, Firefox + plugin-container, Arc), match exact ou préfixe (helpers). Autre bundle = nom `NSRunningApplication`. Exclus : notre pid, `fr.charlesneveu.notekeeper`, process sans bundle, `com.apple.*` qui ne sont pas des apps `.regular` (coreaudiod, Siri, Centre de contrôle). Priorité = ordre de la table. `onChange` sur le main thread, uniquement sur changement. |
| `Permissions.swift` | `AudioPermissions` : état et demande micro (`AVCaptureDevice`), `probeSystemAudio` (tap d'essai 1 s sans autostart : données non nulles = `granted`, erreur = `denied`, silence = `silent`, rien = `noData`), URLs `Privacy_AudioCapture` et `Privacy_Microphone`. |
| `CoreAudioSupport.swift` | Erreur `AudioCaptureError`, `AudioChunk`, `HostClock`, lecture de propriétés CoreAudio, `UnfairLock`, `BufferPool`, `Resampler`, `AudioLog`. |
| `Sources/notekeeper-audiotest/main.swift` | `notekeeper-audiotest <dossier> [secondes] [--probe]` : enregistre `mic.wav` et `system.wav`, RMS des deux pistes et app détectée chaque seconde, cadence des niveaux, durée des WAV. Variables `NOTEKEEPER_TAP_AUTOSTART=1` / `NOTEKEEPER_TAP_SUBDEVICE=0` pour rejouer les variantes de montage. |

## Vérifié (06/09/2026, macOS 26.6, MacBook Air M5, haut-parleurs et micro internes)

Commande : `notekeeper-audiotest <dossier> 8 --probe` avec `say -v Thomas "…"` lancé en parallèle et
QuickTime Player ouvert sur un nouvel enregistrement audio à t = 3 s (fermé sans sauvegarder).

```
audio système : autorisé (données reçues)
micro : Micro MacBook Air / audio système : actif (sortie Haut-parleurs MacBook Air)
  t  rms mic  rms sys  t mic  t sys  app détectée
  1s  0.0246   0.1014   1.11   1.08  aucune
  2s  0.0441   0.1198   2.11   2.09  aucune
  3s  0.0418   0.1521   3.13   3.11  aucune
  4s  0.0538   0.1828   4.15   4.12  aucune
  5s  0.0351   0.1544   5.15   5.14  aucune
  6s  0.0308   0.1186   6.17   6.16  aucune
  7s  0.0249   0.0733   7.19   7.16  QuickTime Player
  8s  0.0027   0.0000   8.20   8.18  QuickTime Player
niveaux : 163 publications en 8.1 s (20.1 Hz), max micro 0.62, max système 0.78
mic.wav : 8.21 s, 262746 octets / system.wav : 8.20 s, 262404 octets
afinfo : 1 ch, 16000 Hz, Int16, 8.209 s et 8.199 s
```

- Piste système nettement non nulle pendant la parole (RMS 0,07 à 0,18), silence quand `say` se tait.
- Les deux pistes restent alignées à 30 ms près sur l'horloge commune pendant toute la prise.
- Même résultat sur AirPods Max en sortie (variante A de la matrice : 8,35 s / 8,47 s, avec le
  micro AirPods à 24 kHz) : l'agrégat avec un sous-device Bluetooth ne pose pas de problème.
- Le build `--product Notekeeper` reste vert (scratch `.build-audio`).

### Deux pièges rencontrés, à ne pas réintroduire

1. **`kAudioAggregateDeviceTapAutoStartKey` gèle tout le process.** Avec la clé à 1, le HAL reste
   bloqué dans `HALC_ProxyIOContext::_StartIO` (vu au `sample`), le tap ne livre rien ET le micro
   AUHAL s'arrête après 0,2 s. Sans la clé, les callbacks arrivent tout de suite (silence si rien ne
   joue). Défaut du module : `autoStart = false`.
2. **`CATapDescription.isExclusive` ne doit pas être touché.** `exclusive` veut dire « tout sauf les
   process listés » ; l'init `stereoGlobalTapButExcludeProcesses` le pose à true. Le forcer à false
   inverse la liste : le tap ne mixe plus que notre propre process et livre du silence parfait.

### Autorisations (personne devant l'écran)

Les autorisations TCC sont attribuées au process responsable : ici le terminal `cmux.app`, déjà
autorisé pour le micro et l'enregistrement audio système. Pour l'app finale, il faudra un bundle avec
`NSMicrophoneUsageDescription` et `NSAudioCaptureUsageDescription` dans son Info.plist ; la boîte
« Enregistrement audio système » s'affiche au premier `AudioHardwareCreateProcessTap`. En cas de refus,
`CaptureSession` continue en micro seul et `lastWarning` pointe vers
`x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture` (à cliquer :
Réglages Système > Confidentialité et sécurité > Enregistrement audio système, activer Notekeeper).

## Ouvert

- Changement de sortie ou de micro **en cours de capture** (AirPods qui se connectent) : le code de
  recréation est en place (débounce 400 ms, recalage par silence) mais n'a pas pu être déclenché
  pendant la session, les AirPods Max s'étant déconnectés entre deux essais. À tester à la main.
- Le probe distingue mal « refusé » de « rien ne jouait » (macOS livre du silence dans les deux cas) :
  l'app devra jouer un son court pendant le probe, ou se fier au verdict `silent` comme indéterminé.
- Détection d'appel : seuls QuickTime (règle « autre app ») et l'absence d'appel ont été vérifiés ;
  Zoom, Teams, Meet dans Chrome et les autres entrées de la table restent à voir sur un vrai appel.
  Un navigateur qui capture le micro hors appel (test micro d'un site) sera compté comme un appel.
- Dérive entre horloges micro et sortie sur une longue réunion : compensée seulement au-delà de
  150 ms d'écart (recalage par silence), pas de rééchantillonnage fin.
