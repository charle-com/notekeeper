# Module PAROLE : transcription Whisper on-device + diarisation

Cible `NotekeeperSpeech` (`Sources/NotekeeperSpeech/`, dépend de `NotekeeperCore`, WhisperKit 0.18, FluidAudio 0.15.6)
et banc d'essai `notekeeper-speechtest` (`Sources/notekeeper-speechtest/`). Le protocole `SpeechEngine` vit dans
`Sources/NotekeeperSpeech/Contracts.swift` (public), retiré du `Contracts.swift` de l'app.

## Implémenté

- `WhisperEngine.swift` (acteur) : modèle `openai_whisper-large-v3-v20240930_turbo_632MB` sous
  `~/Library/Application Support/Notekeeper/huggingface` (copié depuis VoxPrompt par clone APFS s'il y est,
  tokenizer `models/openai/whisper-large-v3` compris, sinon `WhisperKit.download`). Profils de calcul sondés dans
  l'ordre « tout Neural Engine » (mel cpuOnly, encodeur, décodeur et prefill `.cpuAndNeuralEngine`), puis
  « encodeur ANE + décodeur CPU », puis « tout CPU ». Watchdog de chargement 900 s tant que le graphe n'a jamais été
  compilé pour ce build macOS, 120 s ensuite (un budget court qui expire relance le même profil en budget long :
  cache CoreML reconstruit). Réchauffage sur 1 s de bruit (60 s max). Profil mémorisé dans `UserDefaults`
  (`speech.whisper.profile.*`, par build macOS et modèle, re-sondé après 14 jours s'il est dégradé).
  Décodage : `temperature 0`, `temperatureFallbackCount 3`, `usePrefillPrompt true`, `skipSpecialTokens true`,
  `compressionRatioThreshold 2.4`, `logProbThreshold -1.0`, `noSpeechThreshold 0.6`, `chunkingStrategy .vad`,
  `withoutTimestamps` en live. Dictionnaire encodé par le tokenizer en `promptTokens` (100 tokens max,
  `usePrefillCache false` avec prompt, rejeu sans prompt si le résultat est vide). Watchdog par décodage
  `max(20 s, 5 × durée)` ; un gel jette le pipeline et renouvelle l'exécuteur d'inférence (file GCD hors du pool
  coopératif) ; deux gels consécutifs sur un profil font passer au suivant. Détection de boucle en cours de décodage
  (n-gramme répété 4 fois dans le texte partiel) et filtre anti-hallucination en sortie (`HallucinationFilter` :
  segments vides, n-grammes de 1 à 6 mots répétés plus de 3 fois réduits à une occurrence, phrases parasites
  françaises « Sous-titres réalisés par la communauté d'Amara.org », « Merci d'avoir regardé », « Abonnez-vous »...).
- `LiveTranscriber.swift` : par piste, trames de 20 ms, VAD énergétique à seuil adaptatif (3 × plancher de bruit
  estimé sur les trames de silence, minimum 0,003 RMS), pré-roll de 300 ms. Un énoncé se ferme après 700 ms de
  silence ou à 25 s, envoyé seulement s'il contient au moins 400 ms de voix. Inférences sérialisées (une seule à la
  fois, toutes pistes) par un worker unique ; s'il est en retard, les énoncés en attente d'une même piste sont
  fusionnés (200 ms de silence entre eux). Émet `.partial(track:text:"…")` au démarrage de chaque inférence puis
  `.final(TranscriptSegment)` avec `start`/`end` absolus (temps de session de `feed`), `speakerID nil`,
  `isFinal true` (un segment par énoncé). `stopLive()` ferme les énoncés ouverts et attend les dernières inférences.
- `DiarizerService.swift` : FluidAudio offline (`OfflineDiarizerManager`, config `community`), modèles téléchargés
  depuis Hugging Face au premier usage dans `~/Library/Application Support/Notekeeper/FluidAudio/Models/`
  (`prepareModels(directory:)`). `clusterKey` = `speakerId`. Tout échec rend `[]` et un log, jamais de crash.
- `SpeechEngineImpl.swift` : `WhisperSpeechEngine: SpeechEngine`. `prepare` charge Whisper (bloquant) puis le
  diarizer (non bloquant). `finalPass` retranscrit entièrement chaque WAV disponible (horodatages réels,
  `.vad`, WAV supposés démarrer à t = 0 de la session) puis diarise la piste système.
- `Support.swift` : journal (`SpeechLog`, stderr + os_log), erreurs, watchdog à continuation unique,
  `InferenceExecutor` (macOS 15+), lecteur WAV vers Float32 16 kHz mono (`AudioFileLoader`), filtre anti-hallucination.
- `notekeeper-speechtest live|final <mic.wav> <system.wav>` : `live` rejoue les WAV en temps simulé par blocs de
  100 ms et affiche les événements avec leur latence (instant d'émission moins fin de l'énoncé) ; `final` affiche
  segments, spans, facteur temps réel et le transcript fusionné par `TranscriptMerge.assignSpeakers`.

Build : `swift build --scratch-path .build-speech --product notekeeper-speechtest` (et `--product Notekeeper`).

## Vérifié (06/09/2026, MacBook M5 16 Go, macOS 26.6.2 build 25G83, build debug)

Audio de test : voix `say` Thomas + Amélie en alternance avec 1 s de silence (`system.wav`, 56,4 s, 4 prises)
et Jacques seul (`mic.wav`, 33,2 s, 3 prises, 2 s de silence en tête), 16 kHz mono PCM 16 bits, phrases de réunion
avec Alexander, GreenLog, Kheops, ShippingBo, Shopify, Meta. Fichiers dans le scratchpad de session (`speech/`).

- Chargement Whisper, profil retenu « tout Neural Engine » (ane-full) du premier coup, aucun gel :
  lancement 1 = 169,4 s (ANECompilerService à 98 % : compilation du graphe), lancement 2 avec un binaire
  reconstruit = 155 à 178 s (second passage de compilation, dans le processus), lancements suivants avec le même
  binaire = 1,3 à 1,7 s. Réchauffage 0,4 s. Diarizer : 19,2 s au premier usage (téléchargement Hugging Face +
  compilation), 0,1 à 0,8 s ensuite.
- Passage final (`notekeeper-speechtest final`) : 89,6 s d'audio en 5,7 s, facteur temps réel 0,064 (14,9 s et
  0,166 au premier lancement, prompt puis rejeu compris). Micro 33,2 s décodé en 2,0 s, système 56,4 s en 3,2 s.
  Diarisation 56,4 s en 0,47 s : 4 spans, 2 clusters S1/S2 aux bornes attendues (0,00-16,50 / 17,44-31,26 /
  32,22-44,77 / 45,70-56,42 contre 0-16,5 / 17,5-31,3 / 32,3-44,7 / 45,7-56,4 réels). Segments horodatés
  correctement dans le fichier (le décalage des chunks VAD est bien appliqué). Taux d'erreur mot à mot (Levenshtein
  sur mots normalisés, ponctuation et accents ignorés) : micro 7/101 = 6,9 %, système 7/172 = 4,1 %, total 14/273
  = 5,1 %. Les erreurs sont les noms propres non aidés (« Gréant-Logue », « Co », « Coop », « que hop » pour
  Kheops, « Pour moi en log »), « marches » pour marges, « de main » pour demain, « lot 2 », « 20 questions ».
  Le transcript fusionné par `TranscriptMerge.assignSpeakers` donne Moi / Locuteur 2 / Locuteur 3 cohérents.
- Live (`notekeeper-speechtest live`, rejeu temps réel par blocs de 100 ms, pistes égalisées de silence) :
  7 segments finaux (3 micro, 4 système), un par prise, bornes absolues correctes (par exemple système
  17,16-31,52 pour une prise réelle 17,5-31,3). Latence entre la fin de l'énoncé et l'événement `.final` :
  moyenne 1,24 s, min 1,02 s, max 1,44 s (dont 700 ms de fermeture VAD ; décodage de 10 à 17 s d'audio en 0,7 à
  1,0 s). Aucune fusion d'énoncés en retard n'a été nécessaire. `stopLive` immédiat quand la file est vide, 1,5 s
  s'il reste une inférence. Taux d'erreur mot à mot live : micro 6/101 = 5,9 %, système 7/172 = 4,1 %, total
  13/273 = 4,8 %.
- Filtre anti-hallucination : aucun segment parasite ni boucle sur ces fichiers (rien à filtrer, rien de
  cassé). `swift build --product Notekeeper` reste vert.

## Ouvert

- Injection du dictionnaire en `promptTokens` cassée dans WhisperKit 0.18 (résultat vide dès 3 tokens) : désactivée
  (`WhisperEngine.promptInjectionEnabled = false`), remplacée par `DictionaryCorrector` en post-traitement. Il
  corrige la casse et les formes proches (distance 1 à 2) mais pas les déformations phonétiques (« Gréant-Logue »,
  « Co » pour Kheops). Piste : rapprochement phonétique, ou réactiver le prompt quand WhisperKit corrige le
  bookkeeping du cache KV (le filet de rejeu sans prompt couvre déjà la régression).
- Le cache CoreML/ANE est recompilé à chaque nouveau binaire (environ 3 min au premier lancement de chaque build,
  deux fois de suite pour un même binaire dans un cas observé). Marqueur « compilé » désormais lié à l'empreinte de
  l'exécutable et posé seulement après un chargement de moins de 60 s ; à confirmer sur l'app signée
  (`build.sh`), où l'identité de code est stable d'une installation à l'autre.
- Le profil « encodeur ANE + décodeur CPU » et le repli après gel n'ont pas été exercés (aucun gel sur cette
  machine avec macOS 26.6.2) : la logique de probation et de dégradation est écrite mais non observée en conditions
  réelles.
- Horodatages Whisper : le premier segment démarre au début de la fenêtre (micro 0,00 alors que la parole commence
  à 2,0 s). Sans conséquence pour l'attribution des locuteurs (recouvrement majoritaire), à affiner si l'UI veut
  des débuts précis (`wordTimestamps`).
- VAD énergétique seulement : un bruit de fond stationnaire fort (ventilateur, musique) relève le seuil et peut
  perdre une voix faible ; à valider sur une vraie capture système avec le module Audio.
- Diarisation testée sur deux voix de synthèse très différentes ; à valider sur 3 locuteurs et plus, et sur des
  voix proches (le seuil de clustering FluidAudio reste celui de `community`).
