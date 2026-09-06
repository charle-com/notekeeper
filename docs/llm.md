# Module IA et serveur MCP

## Implémenté

### `Sources/NotekeeperCore/LLM/`

| Fichier | Rôle |
| --- | --- |
| `LLMConfig.swift` | Réglages `UserDefaults.standard`, clés `llm.provider` (gemini / ollama), `llm.geminiModel` (`gemini-3.1-pro-preview`), `llm.ollamaModel` (`qwen3:8b`), `llm.ollamaURL` (`http://127.0.0.1:11434`), `llm.userName` (`Moi`). `LLMConfig.load()`, `save()`, `makeClient()`. |
| `Keychain.swift` | Secret générique dans le trousseau (service `fr.charlesneveu.notekeeper`, compte `gemini`) : `read`, `write`, `delete`, `geminiAPIKey()` avec repli sur `GEMINI_API_KEY`. |
| `GeminiClient.swift` | `generateContent` v1beta, `systemInstruction`, `generationConfig` (température 0,2, 8 192 tokens, `responseMimeType: application/json` en mode JSON), timeout 180 s, 2 réessais sur 429 / 5xx / réseau, clé retirée de tout message d'erreur, parties `thought` ignorées. |
| `OllamaClient.swift` | `POST /api/chat`, `stream: false`, `format: json` en mode JSON, température 0,2, message clair si le serveur ou le modèle est absent, balises `<think>` retirées. |
| `MockLLM.swift` | LLM scriptable : file de réponses, règles par mot-clé, handler, erreur à lancer, journal des appels. `MockLLM.demo()` répond à chaque prompt de façon plausible (mode démo de l'UI sans clé). |
| `Prompts.swift` | Prompts en français, fonctions pures qui rendent (system, user) : `identifySpeakers`, `summarize`, `catchUp`, `ask`, `suggestTitle`. Tous interdisent le tiret cadratin et les emojis. |
| `Assistant.swift` | `Assistant(llm:store:userName:)` : `nameSpeakers`, `summarize`, `catchUp`, `ask`, `suggestTitle`. Nettoyage des sorties (tiret cadratin, emojis), troncature début + fin au-delà de 120 000 caractères (80 000 pour le contexte d'une question), parse JSON tolérant (`LLMJSON`). |

Règles de l'assistant :

- `nameSpeakers` : un nom n'est posé que si `confidence >= 0.7`, jamais sur `isMe`, jamais par-dessus un nom existant. Le prompt reçoit les étiquettes techniques (« Moi », « Locuteur 2 »), les invités du calendrier et le dictionnaire personnel comme indices.
- `summarize` : cinq sections imposées dans l'ordre (`## En bref`, `## Décisions`, `## Par thème`, `## Prochaines étapes`, `## Questions ouvertes`) ; une section manquante est ajoutée avec « aucune ». Enregistré dans `summaryMarkdown`.
- `ask` : avec `meetingID`, contexte = transcript complet ; sans, `store.search()` (mots significatifs ensemble, puis chacun séparément) étendu à ± 2 segments voisins et groupé par réunion. Question et réponse archivées dans `chat`. Bloc de citations absent ou cassé = réponse sans citations, jamais d'erreur.

### `Sources/notekeeper-mcp/`

- `main.swift` : `notekeeper-mcp` (base `Store.defaultURL()` ou `NOTEKEEPER_DB`), `--db <chemin>`, `--seed-demo <chemin>`, `--demo-llm <chemin> [question]`, `--help`.
- `MCPServer.swift` : JSON-RPC 2.0 sur stdio, un message par ligne, journal sur stderr. Méthodes `initialize` (renvoie le `protocolVersion` du client), `notifications/initialized`, `ping`, `tools/list`, `tools/call`, plus `resources/list` et `prompts/list` vides. Erreurs `-32700`, `-32600`, `-32601`, `-32602`, `-32603` ; une erreur d'exécution d'outil (réunion introuvable) devient un résultat `isError: true`.
- Outils : `list_meetings` (`limit`, `from`, `to`), `get_meeting` (`id`), `get_transcript` (`id`, `from_seconds`, `to_seconds`), `search_meetings` (`query`, `limit`), `add_note` (`id`, `text`), `rename_speaker` (`meeting_id`, `speaker_id` ou étiquette, `name`).
- `DemoSeed.swift` : deux réunions françaises réalistes (56 et 49 tours, 3 locuteurs dont « Moi », prénoms prononcés dans le texte, invités du calendrier renseignés).
- `DemoLLM.swift` : enchaîne les cinq fonctions de l'assistant sur la première réunion avec le fournisseur configuré.

### Tests et scripts

- `Tests/NotekeeperCoreTests/AssistantTests.swift` : 11 tests sur `MockLLM` + `Store.inMemory()`.
- `docs/mcp-smoke.sh` : base temporaire seedée, session MCP complète par `printf | notekeeper-mcp`, 13 vérifications.

### Modification hors périmètre, documentée

`Store.init(url:)` : `Store.inMemory()` passait `URL(fileURLWithPath: ":memory:").path` à SQLite, soit un vrai fichier `:memory:` créé dans le dossier courant et partagé entre tous les tests (StoreTests échouait dès qu'un autre test laissait des réunions). Le chemin `:memory:` est désormais transmis tel quel. Les fichiers `:memory:`, `:memory:-shm`, `:memory:-wal` à la racine du dépôt sont des résidus de ce bug (le premier est suivi par git) : à retirer avec `git rm --cached` puis suppression.

## Commandes

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
SWIFT="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
"$SWIFT" build --scratch-path .build-llm --product notekeeper-mcp
"$SWIFT" test  --scratch-path .build-llm --filter NotekeeperCoreTests
docs/mcp-smoke.sh

# Essai réel de l'assistant (clé Gemini dans le trousseau ou GEMINI_API_KEY)
.build-llm/debug/notekeeper-mcp --seed-demo /tmp/demo.sqlite
.build-llm/debug/notekeeper-mcp --demo-llm /tmp/demo.sqlite
```

Brancher le serveur dans Claude Code (le binaire doit être compilé, en release de préférence) :

```bash
claude mcp add notekeeper /Users/charlesneveu/Documents/Claude Code/projets/notekeeper/.build-llm/debug/notekeeper-mcp
# ou, sur une autre base :
claude mcp add notekeeper -e NOTEKEEPER_DB=/chemin/notekeeper.sqlite -- /chemin/notekeeper-mcp
```

## Vérifié

- `swift test --filter NotekeeperCoreTests` : 13 tests, 0 échec (AssistantTests 11, StoreTests 2).
- `docs/mcp-smoke.sh` : tout passe (initialize, ping, tools/list, search_meetings, get_transcript, list_meetings, rename_speaker, add_note, get_meeting, erreurs -32601 / -32602 / -32700 / isError, stdout JSON seul).
- `--demo-llm` avec le vrai Gemini : voir ci-dessous.

### Résultats réels (`--demo-llm`, Gemini `gemini-3.1-pro-preview`, 06/09/2026, base seedée)

Réunion « Kick-off refonte site Atelier Morin », 56 tours, 3 locuteurs.

- `nameSpeakers` (14 s) : `Locuteur 2 -> Priya Sharma`, `Locuteur 3 -> Paul Lemaire`. Prénoms entendus dans le texte, noms complets repris des invités du calendrier, « Moi » intact.
- `summarize` (40 s) : les cinq sections dans l'ordre, 7 décisions exactes (o2switch conservé, thème Gutenberg sans slider, Gravity Forms + Sheet, 18 jours, 22 septembre, 31 octobre, devis 10 000 + option 1 700), 6 thèmes avec « qui a dit quoi », 9 prochaines étapes au format « qui : quoi, quand », 1 question ouverte (nom de domaine). Aucune invention, nombres en chiffres, échéances reprises telles quelles (« à la livraison », « ce soir »).
- `suggestTitle` (11 s) : « Refonte du site Atelier Morin ».
- `catchUp` sur les 2 dernières minutes (28 s) : 3 puces, 55 mots, fidèles (migration limitée aux pages avec trafic, redirections, nom de domaine, récapitulatif).
- `ask` sur la réunion (17 s), « Quelle est la date de mise en ligne prévue pour le site et quel budget a été validé ? » : 31 octobre, 10 000 euros + option 1 700 euros, avec 2 citations exactes `[5:18]` et `[5:36]` (texte copié à l'identique, horodatages justes).
- `ask` toutes réunions (12 s), « Combien coûte le petit porteur pour les palettes tampon ? » : la recherche FTS remonte la bonne réunion (« Point transfert entrepôt »), réponse 320 euros attribuée à Marc, 1 citation exacte `[3:58]`.

Corrections de prompts faites après un premier passage : le résumé écrivait « Moi valide » (désormais deuxième personne), déduisait une date (« formation le 31 octobre » pour « à la livraison ») et `catchUp` répondait « Rien de notable » quand l'extrait était surtout parlé par « Moi » (désormais résumé aussi, à la deuxième personne).

## Ouvert

- Le mode JSON de Gemini est demandé par `responseMimeType` ; aucun schéma de réponse n'est imposé (`responseSchema`), le parse tolérant compense.
- `store.search()` combine les termes en ET avec préfixe. Sans réunion ciblée, l'assistant cherche d'abord les mots significatifs ensemble, puis chacun séparément ; si rien ne sort, le LLM est quand même appelé avec un contexte vide (réponse homogène « Je ne trouve pas ça dans tes réunions. »). À court-circuiter côté UI si le coût gêne.
- Latence Gemini 3.1 Pro : 11 à 40 s par appel sur une réunion de 6 minutes ; le résumé d'une réunion d'une heure sera plus long. Un modèle Flash est envisageable pour `catchUp` et `suggestTitle` (clé `llm.geminiModel` unique pour l'instant).
- L'accès au trousseau depuis un binaire non signé peut déclencher une demande d'autorisation macOS la première fois ; en ligne de commande, préférer `GEMINI_API_KEY`.
- Ollama n'a pas été testé en réel (pas de serveur local pendant la session) ; le client est écrit d'après l'API `/api/chat` documentée.
