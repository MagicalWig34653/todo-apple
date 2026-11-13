# Runner: Sprach-Worker (Telefon T1, Schritt 4)

Der Mac-Runner (`TodoRunner`) bearbeitet Sprachaufträge des Kanals #brain (Backend: `contracts/voice.yaml`, `/v1/runner/voice/*`).

## Ablauf
Claim (Lease 60 s, Generation) -> Heartbeat alle 30 s -> Aufnahme laden (SHA-256 aus dem Claim prüfen) -> lokal transkribieren (Deutsch) -> Antworttext (`ResponseProvider`; bis T1-5 feste Quittung) -> Antwortaudio (AVSpeechSynthesizer, M4A, höchstens 120 s / 5 MiB) -> `reply-audio` -> `result`. 409/410/404 auf einem Aufruf bedeuten Besitzverlust: nichts mehr veröffentlichen, Verarbeitung abbrechen. Fehler der Engine werden als `errorCode` gemeldet (`transcription_failed`, `reply_failed`, `audio_corrupt`); fällt nur die Sprachausgabe aus, geht die Antwort als Text.

## Fähigkeit "sprache"
Der Heartbeat `/v1/runner/voice/heartbeat` (alle 30 s) meldet `sprache` nur, wenn das STT-Modell lokal vorhanden ist UND eine deutsche Systemstimme existiert. Prüfen: `todo-runner voice-status`, `todo-runner doctor`.

## Einrichtung
- `todo-runner voice-setup [--model M]`: lädt das WhisperKit-Modell EINMALIG und ausdrücklich (huggingface.co) in `<Zustandsordner>/voice-models` und schreibt `voice.json`. Standard: `openai_whisper-large-v3-v20240930_turbo_632MB` (Apple Silicon, Deutsch); kleiner: `openai_whisper-small_216MB`. Beim Verarbeiten von Audio wird nie nachgeladen (`download: false`, fester Modellordner). Modelle gehören nie ins Repository.
- Deutsche Stimme: Systemeinstellungen > Bedienungshilfen > Gesprochene Inhalte > Systemstimme.
- `todo-runner run` startet den Sprach-Worker automatisch, wenn `voice.json` existiert. `voice-once [--timeout s]` bearbeitet genau einen Auftrag.

## Austauschbare Engine
Protokolle `SpeechToText` und `TextToSpeech` (`Sources/TodoRunner/Voice/VoiceEngines.swift`). Ein externes STT (z. B. VoiceStudio, NICHT gebündelt) wird über `todo-runner voice-setup --http <URL>` angebunden: die Engine muss an Loopback gebunden sein (127.0.0.1, ::1, localhost; andere Hosts lehnt der Runner ab) und einen API-Key verlangen (`TODO_RUNNER_VOICE_KEY`, landet im Schlüsselbund). Vertrag: `POST <URL>/transcribe` mit Rohaudio und `Authorization: Bearer <Key>`, Antwort `{"text": "..."}`.

## Datenschutz
Audio geht nur an den Todolino-Server des Nutzers; Engines laufen lokal. Eingangs-, Zwischen- und Antwortdateien liegen in `<Zustandsordner>/voice-work/<Auftrag>-<Generation>/` (0700), werden nach Erfolg, Fehler und Besitzverlust gelöscht und beim Start eines Workers aufgeräumt. Logs enthalten nur Auftrags-IDs und Fehlercodes, nie Audio, Transkripte oder Antworttexte.

## Tests
- `swift test`: Fakes (Claim-Wettlauf, Lease-Verlust, Fehlerpfade, Löschung, Log ohne Inhalt), URLProtocol-Guard (nur der Server-Host), echte AVSpeech-Ausgabe.
- `scripts/voice-live.sh` (natives Backend, Scratch-SQLite): echter Ablauf mit Gerätetoken; mit `RUNNER_VOICE_MODEL_FOLDER` echte WhisperKit-Transkription; mit `NET_LOOPBACK_ONLY=1` läuft der gesamte Testprozess unter `sandbox-exec`, das nur Loopback erlaubt.
