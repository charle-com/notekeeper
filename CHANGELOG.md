# Changelog

## 1.1.0 (2026-09-07)

Version légère.

- La transcription pendant l'appel est désactivée par défaut (réglage « Transcrire pendant l'appel » dans Général). Pendant l'appel, seul l'audio est enregistré : aucun modèle chargé, aucune inférence.
- Whisper et la diarisation se chargent à la fin de l'appel pour le passage final, puis se déchargent une fois le compte rendu produit (`SpeechEngine.release`). Mémoire au repos et pendant l'appel : celle d'une app vide.
- Le compte rendu gagne une section « Qui a dit quoi » : un bloc par personne, ses annonces, demandes et engagements.
- Le bouton et le raccourci « Qu'est-ce que j'ai raté ? » n'apparaissent que si la transcription pendant l'appel est activée.

## 1.0.0 (2026-09-06)

Première version.

- Capture sans bot : micro (AUHAL entrée seule) + audio système (Core Audio process tap), deux pistes WAV 16 kHz sur une horloge commune.
- Transcription locale WhisperKit large-v3-turbo (Neural Engine), live par VAD puis passage final complet, filtre anti-hallucination, suppression de l'écho acoustique.
- Diarisation offline FluidAudio, attribution des locuteurs, nommage par le LLM (invités du calendrier, dictionnaire, contexte), correction en un clic propagée.
- Résumé structuré (en bref, décisions, par thème, prochaines étapes, questions ouvertes), « Qu'est-ce que j'ai raté ? », titre automatique.
- « Demander » sur une réunion ou tout l'historique, citations cliquables.
- Détection d'appel (app qui ouvre le micro), calendrier, notes markdown, recherche plein texte, export markdown automatique.
- Serveur MCP stdio embarqué (6 outils), réglages Gemini ou Ollama, dictionnaire personnel, barre de menus.
