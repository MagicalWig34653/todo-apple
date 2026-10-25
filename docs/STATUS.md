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
