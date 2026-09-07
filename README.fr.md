# Notekeeper

Prise de notes de réunion pour macOS, open source, sans bot dans l'appel. Transcription locale (Whisper), qui a dit quoi, résumé structuré, « qu'est-ce que j'ai raté ? », questions sur tout ton historique, et un serveur MCP pour brancher Claude Code ou Cursor sur tes réunions.

Clone libre de Wispr Flow Notetaker. Fonctionne avec Zoom, Google Meet, Teams, FaceTime, WhatsApp, Slack, Discord, et les réunions en présentiel (micro seul).

[English version](README.md)

## Ce que ça fait

- **Capture sans bot** : le micro (toi) et l'audio système (les autres) sur deux pistes séparées, via Core Audio. Rien à installer dans Zoom ou Meet, personne n'est invité.
- **Transcription locale** : Whisper large-v3-turbo par WhisperKit, sur le Neural Engine. L'audio ne quitte jamais le Mac.
- **Qui a dit quoi** : ta piste porte ton nom ; les autres voix sont séparées par diarisation (FluidAudio, modèles pyannote et WeSpeaker en CoreML), puis nommées par le LLM à partir des invités du calendrier, du dictionnaire personnel et de ce qui se dit (« merci Priya »). Un clic pour corriger, tout le transcript suit.
- **Résumé structuré** : en bref, décisions, points par thème, prochaines étapes (qui, quoi, quand), questions ouvertes.
- **Léger pendant l'appel** : par défaut seul l'audio est enregistré, Whisper se charge à la fin puis se décharge. Le transcript en direct et « Qu'est-ce que j'ai raté ? » (résumé des dernières minutes) s'activent dans les réglages, au prix d'environ 1 Go de mémoire résidente.
- **Demander** : une question sur une réunion ou sur tout l'historique, réponse avec citations cliquables qui ouvrent le passage.
- **Mes notes** : un éditeur markdown à côté du transcript.
- **Détection d'appel** : Notekeeper voit quelle app utilise le micro et propose d'enregistrer. Le calendrier fournit le titre et les invités.
- **Export markdown** : un fichier par réunion dans `~/Documents/Notekeeper/` (lisible dans Obsidian).
- **Serveur MCP** : `notekeeper-mcp` expose `list_meetings`, `get_meeting`, `get_transcript`, `search_meetings`, `add_note`, `rename_speaker` à Claude Code, Cursor, Claude Desktop.

Ce qui part dans le cloud : uniquement le texte du transcript vers le fournisseur LLM choisi (Gemini par défaut, Ollama en local possible), pour les noms, le résumé et les questions. Jamais l'audio.

## Installation

Prérequis : macOS 14.4 ou plus (Apple Silicon recommandé), Xcode installé.

```bash
git clone https://github.com/charle-com/notekeeper.git
cd notekeeper
./setup-signing.sh      # une fois : identité de signature stable, pour garder les autorisations entre versions
./build.sh --install    # compile, signe, installe dans /Applications
```

Au premier lancement : ton nom, les autorisations (micro, enregistrement audio système, calendrier), puis le chargement de Whisper (632 Mo téléchargés une fois, première compilation CoreML de quelques minutes).

Réglages > IA : colle une clé Gemini (gratuite sur aistudio.google.com) ou bascule sur Ollama.

## Brancher Claude Code

Réglages > MCP donne la commande, qui ressemble à :

```bash
claude mcp add notekeeper "/Applications/Notekeeper.app/Contents/MacOS/notekeeper-mcp"
```

Ensuite, dans Claude Code : « qu'est-ce qu'on a décidé sur les prix la semaine dernière ? ».

## Architecture

| Cible | Rôle |
|---|---|
| `NotekeeperCore` | Modèles, base SQLite (FTS5), fusion des pistes, prompts, clients LLM (Gemini, Ollama), export markdown. Testé. |
| `NotekeeperAudio` | Micro (AUHAL entrée seule), audio système (Core Audio process tap), WAV, détection d'appel, autorisations. |
| `NotekeeperSpeech` | WhisperKit (live par VAD et passage final), diarisation FluidAudio, filtres anti-hallucination. |
| `Notekeeper` | L'app SwiftUI : fenêtre principale, transcript live, résumé, notes, « demander », barre de menus, réglages. |
| `notekeeper-mcp` | Serveur MCP stdio (JSON-RPC, un message par ligne). |
| `notekeeper-audiotest`, `notekeeper-speechtest` | Bancs d'essai en ligne de commande. |

Détails par module dans `docs/`.

## Pendant une réunion

1. ⇧⌘R ou le bouton Enregistrer (ou la proposition automatique quand un appel démarre).
2. Le transcript défile, ta voix en couleur d'accent, les autres en gris-bleu. Vumètres des deux pistes.
3. « Qu'est-ce que j'ai raté ? » (⇧⌘M) résume les dernières minutes.
4. Terminer : retranscription complète, séparation des voix, noms, résumé, titre, export.

## Consentement

Préviens toujours les participants avant d'enregistrer. Notekeeper capture l'audio localement et n'envoie aucune notification à ta place. La loi sur l'enregistrement des conversations varie selon le pays.

## Licence

MIT.
