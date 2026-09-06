import Foundation
import NotekeeperCore
import NotekeeperAudio

/// Contrats entre les modules de l'app. Chaque module en implémente un, l'UI ne connaît que ceux-ci.
/// Temps : toutes les positions sont en secondes depuis le début de la capture (`start()`),
/// identiques sur les deux pistes.

/// `CaptureEngine` et `CallDetector` vivent dans le module `NotekeeperAudio` (Contracts.swift),
/// partagé avec l'outil de test `notekeeper-audiotest`.
/// `SpeechEngine` vit dans le module `NotekeeperSpeech` (Sources/NotekeeperSpeech/Contracts.swift).
