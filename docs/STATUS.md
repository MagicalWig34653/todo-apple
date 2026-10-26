# Apple – Status

Stand 26.10.2026, Branch `feature/etappe1-client`. Globale Doku und Arbeitsplan: Hauptrepository (Pfad in `.workspace.local.json`).

## Vorhanden
- `TodoCore/` (plattformneutral, ohne Backend-Abhängigkeit): `APIClient` für `/v1` (Capabilities, Passkey-Registrierung per Bootstrap/Einladung, Passkey-Login, Passwort-Login nur wenn der Server ihn anbietet, me, Logout, Einladung erzeugen, Projekte und Aufgaben CRUD mit `version`), `APIError` (u. a. `versionConflict`, `passwordLoginDisabled`), Codable-DTOs, `TokenStore` (Keychain, In-Memory), `PasskeyAuthenticator`-Protokoll, `ProjectTree` (verschachtelte Projekte). Bearer-Token statt Cookies.
- `App/Shared` (iOS und macOS): `PlatformPasskey` (ASAuthorizationPlatformPublicKeyCredentialProvider), `AppModel` (Zustand, einfache Konfliktpolitik: Server gewinnt, neu laden, Hinweis), Login/Einrichtung (Server-Adresse, Passkey, Token-Einrichtung, "Andere Anmeldemethode" nur bei `capabilities.password`), Projektbaum, Aufgabenliste mit Schnellerfassung, Abhaken, Löschen. Texte Deutsch in `Localizable.xcstrings` (Schlüssel, Quellsprache de).
- `App/Watch`: nur Platzhalter-App.
- Konfiguration: Server-Adresse Standard `http://127.0.0.1:28080`, änderbar im Login. RP-ID kommt vom Server (Optionen), die App braucht nur die Associated-Domain. `App/Config/Todo.entitlements.example` ist die dokumentierte TODO-Konfiguration (Platzhalter `todo.example.invalid`, nicht eingebunden).

## Geprüft
- `xcodebuild test -scheme TodoCore -destination 'platform=macOS'`: 10 Tests grün (URLProtocol-Mock: Request-Formen für Registrierung/Login/Update, Bearer und Query, Fehlerabbildung inkl. 409 version_conflict, Logout bei ungültiger Sitzung, moveToRoot, Projektbaum). Zusätzlich Live-Test gegen lokales Backend (`TEST_RUNNER_TODO_LIVE_BASE_URL=http://127.0.0.1:28080`, sonst übersprungen): Health, Capabilities, 401 ohne Sitzung, Passwort-Login korrekt abgewiesen (Passwort war serverseitig aus): grün.
- Builds mit `CODE_SIGNING_ALLOWED=NO`: Todo-iOS (generic Simulator), Todo-macOS, Todo-watchOS (generic Simulator) erfolgreich.
- `swift test` scheitert weiterhin am Codesigning; Worktree liegt außerhalb von Documents (`/private/tmp/claude-501/wt/todo-apple`).

## Nicht geprüft / Grenzen
- Passkey-Ceremony (Registrierung und Login) auf Gerät/Simulator: nicht geprüft; braucht echte Domain, Associated Domains, AASA. Die Request-Formen sind nur gegen die Backend-Quelltypen (webauthn-swift) und per Mock geprüft, nicht Ende-zu-Ende. Ein virtueller Authenticator in Swift gegen das Backend wäre ein möglicher nächster Test.
- Passwort-Login live mit Erfolg nicht geprüft (kein Konto mit Passwort ohne Passkey anlegbar).
- UI nie gestartet (nur Build); Keychain-Store ohne Test (unsigned Testhost).
- Watch: keine Anmeldung/Aufgaben (Sitzungsübernahme noch nicht entworfen).
- Keine Offline-Erfassung, kein Projekt-Umbenennen/Verschieben in der UI (API vorhanden), Apple-Hinweis: Version-Konflikt zeigt nur Hinweis.

## Nächster Schritt
Echte Domain/RP-ID festlegen, Entitlement aktivieren, Passkey auf Gerät prüfen; UI im Simulator ansehen; Watch-Sitzungsübernahme entwerfen.
