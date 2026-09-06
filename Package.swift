// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Notekeeper",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Whisper on-device (CoreML, Neural Engine). Même version que VoxPrompt.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "0.18.0"),
        // Diarisation on-device (pyannote segmentation + WeSpeaker, CoreML).
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.6"),
    ],
    targets: [
        // Logique pure : modèles, base SQLite (FTS5), fusion des pistes, prompts, clients LLM,
        // export markdown. Aucune dépendance AppKit : testable et partagé avec le serveur MCP.
        .target(
            name: "NotekeeperCore",
            path: "Sources/NotekeeperCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // L'application macOS (SwiftUI) : capture audio, transcription live, diarisation, UI.
        .executableTarget(
            name: "Notekeeper",
            dependencies: [
                "NotekeeperCore",
                "NotekeeperAudio",
                "NotekeeperSpeech",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/Notekeeper",
            resources: [.copy("Assets")]
        ),
        // Capture audio : micro (AUHAL entrée seule) + audio système (process tap), WAV, niveaux,
        // détection d'appel. Partagé entre l'app et l'outil de test notekeeper-audiotest.
        .target(
            name: "NotekeeperAudio",
            dependencies: ["NotekeeperCore"],
            path: "Sources/NotekeeperAudio"
        ),
        // Test de terrain de la capture : notekeeper-audiotest <dossier> [secondes].
        .executableTarget(
            name: "notekeeper-audiotest",
            dependencies: ["NotekeeperAudio", "NotekeeperCore"],
            path: "Sources/notekeeper-audiotest"
        ),
        // Parole : transcription Whisper on-device (WhisperKit) et diarisation (FluidAudio).
        // Sans AppKit : partagé entre l'app et l'exécutable de test notekeeper-speechtest.
        .target(
            name: "NotekeeperSpeech",
            dependencies: [
                "NotekeeperCore",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/NotekeeperSpeech"
        ),
        // Banc d'essai parole : `live` (rejeu temps simulé) et `final` (passage final + diarisation).
        .executableTarget(
            name: "notekeeper-speechtest",
            dependencies: ["NotekeeperCore", "NotekeeperSpeech"],
            path: "Sources/notekeeper-speechtest"
        ),
        // Serveur MCP (stdio, JSON-RPC) : expose les réunions à Claude Code, Cursor, etc.
        .executableTarget(
            name: "notekeeper-mcp",
            dependencies: ["NotekeeperCore"],
            path: "Sources/notekeeper-mcp"
        ),
        .testTarget(
            name: "NotekeeperCoreTests",
            dependencies: ["NotekeeperCore"],
            path: "Tests/NotekeeperCoreTests"
        ),
    ]
)
