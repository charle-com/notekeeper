# Notekeeper

Open source meeting notes for macOS, with no bot in the call. Local transcription (Whisper), who said what, structured summary, "what did I miss?", questions across your whole history, and an MCP server so Claude Code or Cursor can read your meetings.

A free clone of Wispr Flow Notetaker. Works with Zoom, Google Meet, Teams, FaceTime, WhatsApp, Slack, Discord, and in-person meetings (mic only).

[Version française](README.fr.md)

## Features

- **No bot capture**: your mic (you) and the system audio (everyone else) on two separate tracks via Core Audio. Nothing to install in Zoom or Meet, nobody gets invited.
- **Local transcription**: Whisper large-v3-turbo through WhisperKit on the Neural Engine. Audio never leaves the Mac.
- **Who said what**: your track carries your name; the other voices are separated by diarization (FluidAudio, pyannote and WeSpeaker CoreML models), then named by the LLM from calendar invitees, your personal dictionary and what is said ("thanks Priya"). One click to fix a name, the whole transcript follows.
- **Structured summary**: in brief, who said what (one block per person), decisions, topics, next steps (who, what, when), open questions.
- **Light during the call**: by default only the audio is recorded; Whisper loads when the call ends and unloads once the summary is written. Live transcript and "What did I miss?" (a three-line recap of the last few minutes) can be enabled in Settings, at the cost of about 1 GB of resident memory.
- **Ask**: a question about one meeting or the whole history, answered with clickable citations that open the passage.
- **My notes**: a markdown editor next to the transcript.
- **Call detection**: Notekeeper sees which app is using the microphone and offers to record. The calendar provides the title and invitees.
- **Markdown export**: one file per meeting in `~/Documents/Notekeeper/` (Obsidian friendly).
- **MCP server**: `notekeeper-mcp` exposes `list_meetings`, `get_meeting`, `get_transcript`, `search_meetings`, `add_note`, `rename_speaker` to Claude Code, Cursor, Claude Desktop.

What goes to the cloud: only the transcript text, to the LLM provider you pick (Gemini by default, Ollama for fully local), for names, summary and questions. Never the audio.

## Install

Requires macOS 14.4+ (Apple Silicon recommended) and Xcode.

```bash
git clone https://github.com/charle-com/notekeeper.git
cd notekeeper
./setup-signing.sh      # once: stable signing identity so permissions survive rebuilds
./build.sh --install    # build, sign, install into /Applications
```

First launch: your name, permissions (microphone, system audio recording, calendar), then the Whisper model (632 MB downloaded once, a few minutes of CoreML compilation the first time).

Settings > AI: paste a Gemini key (free at aistudio.google.com) or switch to Ollama.

## Connect Claude Code

Settings > MCP shows the command:

```bash
claude mcp add notekeeper "/Applications/Notekeeper.app/Contents/MacOS/notekeeper-mcp"
```

## Architecture

| Target | Role |
|---|---|
| `NotekeeperCore` | Models, SQLite (FTS5), track merging, prompts, LLM clients (Gemini, Ollama), markdown export. Tested. |
| `NotekeeperAudio` | Mic (input-only AUHAL), system audio (Core Audio process tap), WAV, call detection, permissions. |
| `NotekeeperSpeech` | WhisperKit (VAD-driven live pass and final pass), FluidAudio diarization, hallucination filters. |
| `Notekeeper` | The SwiftUI app: main window, live transcript, summary, notes, ask, menu bar, settings. |
| `notekeeper-mcp` | Stdio MCP server (newline-delimited JSON-RPC). |
| `notekeeper-audiotest`, `notekeeper-speechtest` | Command-line test benches. |

The interface is in French. Per-module details live in `docs/`.

## Consent

Always tell participants before recording. Notekeeper captures audio locally and does not notify anyone for you. Recording laws vary by country.

## License

MIT.
