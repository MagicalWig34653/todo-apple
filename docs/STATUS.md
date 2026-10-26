# Apple – Status

Stand 25.10.2026. Globale Doku und Arbeitsplan: Hauptrepository (Pfad in `.workspace.local.json`).

## Vorhanden (unversioniert, keine Commits)
- `TodoCore/`: Swift Package (iOS 17, macOS 14, watchOS 10) mit `APIClient.ready()` und `HealthResponse`; ein Decoding-Test.
- `App/TodoApp.swift`: Minimal-SwiftUI-App, zeigt Backend-Erreichbarkeit (Platzhalter-URL `http://127.0.0.1:28080`).
- `project.yml` (XcodeGen): Targets `Todo-iOS`, `Todo-macOS`, `Todo-watchOS`; Bundle-IDs `example.todo.*` sind Platzhalter. `Todo.xcodeproj` wird mit `xcodegen` erzeugt und ist ignoriert.

## Geprüft
- `xcodebuild … build CODE_SIGNING_ALLOWED=NO`: iOS (generic Simulator), macOS und watchOS (generic Simulator) erfolgreich.
- `xcodebuild test -scheme TodoCore -destination 'platform=macOS'`: 1 Test grün. `swift test` scheitert hier am Codesigning des `.xctest` (nicht untersucht).

## Nicht geprüft
Start im Simulator/auf Gerät, Netzwerkzugriff zum Backend, Signierung, Passkeys, Associated Domains, Runner-Code (Konzept: ADR 0004 im Hauptrepo).

## Nächster Schritt
Nach Backend-Auth (Etappe 1): Login/Passkey und Projekt-/Aufgabenliste im Client gegen `contracts/openapi.yaml`.

## Runner (TodoRunner, 26.10.2026, Branch feature/runner)
Stand: Swift Package `TodoRunner/` (macOS 14, Bibliothek + CLI `todo-runner`) auf Basis des Server-Vertrags `contracts/agents.yaml` (Hauptrepo, nur gelesen). Der unverifizierte Codex-WIP wurde ersetzt.
- `ClaudeProcessAdapter` (hinter `AgentProvider`): `claude -p ... --session-id|--resume <uuid> --output-format json --allowedTools ... --permission-mode dontAsk --max-turns N`, `--json-schema` fuer `text`/`question`/`options`, keine MCP-Server. Eigene Prozessgruppe (posix_spawn), Ausgabe in Dateien, Timeout/Stop per SIGKILL auf die Gruppe, PID-Identitaet ueber Startzeit (kein Signal an wiederverwendete PIDs), Adoption eines verwaisten Prozesses nach Runner-Neustart.
- `URLSessionRunnerServer` + `RunnerServer`-Protokoll: alle `/v1/runner/*`-Endpunkte (pair, bindings, jobs, detail, claim, runs, heartbeat, progress, checkpoint, question, resume, submit, stop, fail, reconcile); 409/410 => `isOwnershipLoss`.
- `Runner` (Zustandsmaschine): beim Start zuerst `GET runs` + lokal abgleichen, erst dann Claim; Zustand vor jedem externen Effekt atomar gespeichert (temp+rename, 0600, flock-Einzelschreiber); hoechstens ein Lauf pro Ordner; Heartbeat auch in der Fragenpause; Frage => Checkpoint + question, Fortsetzung per `--resume` mit derselben Session erst nach Antwort; Ende => Checkpoint + submit (awaiting_review) oder fail; Lease-Verlust (409/410, lokaler Ablauf) sperrt Veroeffentlichung, killt den Prozess, bestaetigt `reconcile stopped`; menschlicher Stop (cancelled) stoppt lokal und bestaetigt `stop`; unklarer Prozess/Spawn-Absturz => `needsReconciliation`, nie blinder Neustart, Freigabe nur per `todo-runner release`.
- Ordner-Allowlist lokal (`allowlist.json`: Repository-UUID => exakter kanonischer Pfad, Symlink-Umleitung wird abgelehnt); Pfade verlassen das Geraet nicht.
- CLI: `pair`, `approve`, `bindings`, `status`, `run`, `release`. Konfiguration in `$TODO_RUNNER_HOME/config.json` (0600).
Pruefungen: `swift test` (Build ausserhalb von Documents, `--scratch-path /private/tmp/...`): 37 Tests gruen, mehrfach wiederholt (Fake-Server/-Provider: Neustart-Abgleich, Doppelstart, Lease-Verlust, Stop, Frage/Fortsetzung; URLProtocol-Mock fuer die REST-Schicht; Adapter mit Shell-Skripten). Mit `RUNNER_LIVE=1`: 2 Live-Tests gegen die echte `claude` 2.1.310 gruen (Datei lesen via Runner bis submit; Session per UUID fortsetzen, Kontext bleibt). Hinweis: `--json-schema` verbraucht Turns (max-turns 3 reichte nicht, Standard hier 20).
Nicht geprueft: Lauf gegen das echte Backend (kein E2E, Docker nicht gestartet); Frage-/Rueckfragepfad mit echter claude-CLI; Schlaf/gesperrter Mac; macOS-App-Sandbox; Token im Keychain statt Datei; automatische Wiederaufnahme nach `needsReconciliation` (nur manuell); Fortschrittsmeldungen waehrend des Laufs (nur Start/Ende); Checkpoint-Kontextrevision wird nur aus der Freigaberevision abgeleitet; Token-Widerruf-Verhalten.
Naechster Schritt: E2E gegen lokales Backend (pair, binding, Freigabe, Lauf, Frage/Antwort), dann Runner-Steuerung in der Mac-App.
