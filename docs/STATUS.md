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

## Checkpoint 27.10.2026 (TestFlight-Vorbereitung)

- `App/Config/Base.xcconfig`, `Signing.local.xcconfig.example`, `PrivacyInfo.xcprivacy`, `ExportOptions.plist`, `scripts/testflight-archive.sh`, `docs/TESTFLIGHT.md` angelegt.
- Verifiziert: unsignierter Archive-Build (`TODO_UNSIGNED=1`) für generisches iOS erfolgreich. Nicht verifiziert: signierter Export, Upload, Passkey-Domain.
- Offen: Team-ID, App-Store-Connect-Eintrag, Domain + apple-app-site-association, App-Icon (`App/Icon/AppIcon.icon`; XcodeGen-Aufnahme ungetestet), Bundle-Präfix (Platzhalter `example.todo`).

## Checkpoint 27.10.2026 (Signierung/Bundle-ID)
- Entscheidung: iOS-Bundle-ID `de.linolaske.todo` (Prefix selbst), macOS `.mac`, watchOS `.watch`; Team `J2DU2P47XW` (nur lokal in gitignorierter `Signing.local.xcconfig`); Passkey/RP-Domain `todo.linolaske.de`.
- `Todo.entitlements` (`webcredentials:todo.linolaske.de`) aktiv, via `project.yml` fuer iOS und macOS. AASA-Datei fertig unter `docs/aasa/apple-app-site-association`, Hosting auf dem Server offen.
- Signierter Archiv-/Export-Lauf erfolgreich (App-ID automatisch angelegt, Apple Distribution Zertifikat cloud-managed, IPA exportiert, nichts hochgeladen). Details und Stolperstein (`TODO_OUT_DIR` ausserhalb Documents) in `docs/TESTFLIGHT.md`.
- Offen: App-Store-Connect-Eintrag (Nutzer), AASA auf `todo.linolaske.de` ausliefern, Upload, Passkey-Test auf Geraet. macOS-App-ID `de.linolaske.todo.mac` noch nicht registriert/signiert geprueft.

## Checkpoint 27.10.2026 (TestFlight-Upload)
- `scripts/testflight-archive.sh` hat jetzt `TODO_UPLOAD=1` (Export mit `destination=upload`, Xcode-Konto, keine Zugangsdaten im Repo).
- Upload erfolgreich: 0.1.0 Build 2610271206, Delivery UUID `76573aed-cc05-4e99-bbfa-e425d8429ce4`, keine Validierungsfehler/Warnungen in den Distribution-Logs. Details in `docs/TESTFLIGHT.md`.
- Offen: Verarbeitung in App Store Connect abwarten, Build Testgruppe zuweisen, AASA auf Server ausliefern, Passkey-Test auf Geraet, Datenschutz-Angaben in ASC.
## Checkpoint 27.10.2026 (Etappe 2 Client, Branch feature/etappe2-apple)
Ziel: Apple-Client fuer Planung, Zusammenarbeit, Suche, Teams/Freigaben und Sync gegen die Vertraege `planning-ext`, `collaboration`, `discovery`, `sharing`, `attachments`, `sync` (Hauptrepo `contracts/`). Der fruehere Codex-Branch `feature/etappe2-client` blieb leer und wird nicht verwendet.
- TodoCore (neu): `Planning.swift` (PlanningData/PlanningTask, today/upcoming/up-next, GET/PUT planning; PUT sendet explizit `null` fuer geloeschte Termine; Daten ISO-8601), `Discovery.swift` (TaskLabel, Labels CRUD und Task-Zuordnung, `search` mit q/projectID/labelID/status/Paging), `Collaboration.swift` (Kommentare inkl. Idempotency-Key und DELETE mit Version, Aktivitaet mit Cursor, Anhang-Metadaten `TaskAttachment`), `Sharing.swift` (Teams, Mitglieder, Einladungen, Annahme, `users/search`, Grants, Vererbung, Sichtbarkeit), `Sync.swift` (`syncChanges`, `syncAll` folgt hasMore, `applyMutation` mit mutationID, 201 => `created`). `APIClient`: Header, PUT-Body, DELETE-Body, Status-Rueckgabe. Namen `TaskLabel`/`TaskAttachment`, um Kollisionen mit SwiftUI zu vermeiden.
- App/Shared: Seitenleiste mit Heute, Anstehend, Suche, Teams und Projektbaum (`SidebarItem`); Agenda-Listen, Aufgabendetail (Titel/Beschreibung/Status, Faelligkeit/Geplant/Prioritaet, Labels, Kommentare, Aktivitaet, Anhangsliste), Suche, Teams (Einladungen annehmen, Mitglieder einladen per Personensuche), Projekt-Freigabe-Sheet (Grants fuer Personen/Teams, Rolle, Vererbung). Texte Deutsch in `Localizable.xcstrings`.
- Geprueft: `xcodebuild test -scheme TodoCore -destination platform=macOS`: 21 Tests (1 Live-Test uebersprungen), 0 Fehler; davon 10 neue (URLProtocol-Mock: Request-Formen, Decoding, Paging, Fehlerabbildung inkl. cursor_ahead/invalid_cursor/version_conflict/mutation_id_reused). `xcodebuild build` (CODE_SIGNING_ALLOWED=NO) fuer Todo-iOS (generic Simulator), Todo-macOS und Todo-watchOS erfolgreich; DerivedData unter /private/tmp/claude-501/.
- Nicht geprueft: UI nie gestartet (nur Build); nichts gegen das echte Backend (kein Live-Test fuer die neuen Endpunkte); Sync wird noch nicht von der App benutzt (keine lokale Persistenz/Offline-Warteschlange, App laedt weiter per REST); Anhaenge nur Metadaten (kein Upload/Download/Vorschau); keine Erinnerungs-/Wiederholungs-UI, keine Meilensteine/Abhaengigkeiten/Board, keine gespeicherten Filter; Rollen werden nicht UI-seitig ausgeblendet (Server entscheidet, 403 => Hinweis); Personennamen in der Grant-Liste nur fuer Teams und das eigene Konto bekannt (Vertrag liefert keine Namen).
- Naechster Schritt: Live-Test gegen lokales Backend; Sync-Engine mit lokalem Speicher und Mutations-Warteschlange; Anhang-Upload/-Vorschau; UI im Simulator pruefen.
