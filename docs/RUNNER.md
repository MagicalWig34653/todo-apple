# Todo Runner (Mac) – Einrichtung, Sicherheit, Fehlersuche

Der Runner (`todo-runner`, Swift Package `TodoRunner/`) nimmt Aufträge der Steuerzentrale an, startet dafür die lokale `claude`-CLI in einem freigegebenen Ordner und meldet Fortschritt, Rückfragen und Ergebnis über die Runner-API (`contracts/agents.yaml`, Abschnitt `/v1/runner`, Hauptrepository). Die Zustandsmaschine ist in `docs/STATUS.md` (Abschnitt Runner) beschrieben; dieses Dokument ist die Bedienungs- und Sicherheitsanleitung.

## Einrichtung

Voraussetzungen: macOS 14 oder neuer, Claude Code installiert und angemeldet (`claude` in einem Terminal starten), Konto mit einem Projekt in der Steuerzentrale.

1. Bauen: `cd TodoRunner && swift build -c release --scratch-path /private/tmp/todo-runner-build` (Binary: `/private/tmp/todo-runner-build/release/todo-runner`, an einen festen Ort kopieren, z. B. `~/.local/bin/todo-runner`).
2. Koppeln: In der App (Agenten und Runner) bzw. Weboberfläche einen Kopplungscode erzeugen, dann
   `todo-runner pair https://<server> <Code>`
   Das Geräte-Token landet im macOS-Schlüsselbund (Dienst `de.todo.runner`), in `config.json` stehen nur Server-URL und Geräte-ID.
3. Ordner freigeben: `todo-runner approve ~/Code/mein-projekt` gibt die Repository-UUID aus. Diese UUID beim Verbinden des Projekts mit dem Gerät (Binding) verwenden; alternativ `todo-runner approve <Ordner> <UUID>`, wenn das Binding schon existiert (`todo-runner bindings` listet sie).
4. Prüfen: `todo-runner doctor`. Er prüft die claude-CLI (`--version`), Zustandsordner-Rechte, Kopplung und Token, Erreichbarkeit des Servers (authentifizierter Aufruf, prüft also auch das Token), freigegebene Ordner (vorhanden, les- und schreibbar), Bindings ohne Ordner und unklare Läufe. Exit-Code 1 bei Fehlern.
5. Starten:
   - einmalig im Vordergrund: `todo-runner run-once` nimmt höchstens einen Auftrag an, arbeitet ihn bis zu einem Ruhepunkt ab (beendet, wartet auf Antwort, unklar) und endet (Exit-Code 2 bei unklarem Lauf oder Besitzverlust);
   - dauerhaft: `todo-runner run` (Abfrage alle 15 s, `TODO_RUNNER_INTERVAL` ändert das).
6. Autostart (optional): `todo-runner launchd-plist` gibt einen LaunchAgent aus. Der Befehl installiert nichts. Aktivieren: Log-Ordner anlegen (`mkdir -p <Zustandsordner>/logs`), Ausgabe nach `~/Library/LaunchAgents/de.todo.runner.plist` speichern, `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/de.todo.runner.plist`. Entfernen: `launchctl bootout gui/$(id -u)/de.todo.runner`. Der Agent läuft in der Benutzersitzung, damit Schlüsselbund und Claude-Anmeldung verfügbar sind. Beim Beenden des Runners laufen gestartete `claude`-Prozesse weiter und werden beim nächsten Start wieder übernommen.

Weitere Befehle: `status` (Kopplung, Läufe; `--json` für Rohdaten, funktioniert auch während der Runner läuft), `logs [-n 50]`, `release <Lauf-UUID>`, `bindings`.

Umgebungsvariablen: `TODO_RUNNER_HOME` (Zustandsordner, Standard `~/Library/Application Support/TodoRunner`), `TODO_RUNNER_CLAUDE` (Pfad der claude-CLI, Standard `~/.local/bin/claude`), `TODO_RUNNER_INTERVAL`, `TODO_RUNNER_SECRETS=file` (Token als 0600-Datei statt im Schlüsselbund, nur für Tests und Headless-Umgebungen).

## Ablauf eines Laufs

Annehmen (claim) und Heartbeat halten die Lease (rund 90 s). Der Runner startet `claude -p ... --output-format stream-json --verbose`, liest die Ausgabe laufend mit und meldet gedrosselt (mindestens 30 s Abstand) eine kurze Zusammenfassung der Werkzeugschritte als Fortschritt, z. B. „Agent arbeitet: 3 Dateien gelesen, 1 Suche, 2 Änderungen (a.swift, b.swift)“. Es werden nur Werkzeugart, Anzahl und bei Änderungen der Dateiname übertragen, nie Pfade, Dateiinhalte oder Befehle. Am Ende folgen Checkpoint und Ergebnis zur Prüfung, bei einer Rückfrage Checkpoint und Frage; nach der Antwort wird dieselbe Claude-Sitzung (`--resume <UUID>`) fortgesetzt.

Der Prompt weist Claude an, bei verfügbaren Todo-MCP-Werkzeugen zuerst `get_manual` aufzurufen und dem Handbuch zu folgen; ohne MCP (der Runner startet Claude derzeit mit leerer MCP-Konfiguration) läuft der Auftrag ohne. Rückfragen stellt der Agent über das strukturierte Ergebnisfeld `question`, nicht im freien Chat.

## Ruhezustand und Bildschirmsperre

- Während ein Agent läuft, hält der Runner eine Aktivitätszusicherung (`ProcessInfo.beginActivity`, Leerlauf-Ruhezustand des Systems verhindert, wie `caffeinate -i`). Der Bildschirm darf ausgehen und sich sperren; Prozesse laufen weiter. Die Zusicherung endet, sobald kein Agent mehr läuft (auch in der Fragenpause; dort ist Ruhezustand erlaubt).
- Erzwungener Ruhezustand (Deckel zu, Akku leer) ist nicht zu verhindern. Beim Aufwachen erkennt der Runner den Zeitsprung (Wanduhr gegen Wachzeit) und versucht für 5 Minuten, die abgelaufene Lease über `reconcile alive` (bzw. `paused` in der Fragenpause) neu zu übernehmen; schlägt das mangels Netz fehl, wird bis Ablauf der Frist wiederholt. Lehnt der Server ab oder läuft die Frist ab, wird der Lauf als unterbrochen markiert („Interrupted by sleep“), der Prozess beendet und dem Server `stopped` bestätigt; der Auftrag gilt dann als fehlgeschlagen und kann neu freigegeben werden. Es bleibt nichts hängen.
- Das Zeitlimit eines Laufs (30 min) zählt nur Wachzeit.

## Sicherheitsmodell

- Gerät und Token: Das Geräte-Token gilt nur für die Runner-API und liegt im Schlüsselbund (nach erstem Entsperren, nur dieses Gerät). Es wird nie geloggt: Logs und Fehlermeldungen laufen durch eine Schwärzung (registriertes Token und `Bearer ...`). Ein altes Klartext-Token in `config.json` wird beim ersten Start in den Schlüsselbund verschoben. Widerruf in der App macht das Token ungültig (`doctor`: „Token ungültig oder Gerät widerrufen“).
- Arbeitsverzeichnis-Allowlist: Aufträge laufen nur in Ordnern, die lokal per `approve` freigegeben wurden (genau ein kanonischer Pfad je Repository-UUID, keine Vererbung auf Unterordner oder Elternordner, Symlink- und Alias-Umleitungen werden abgelehnt). Pfade verlassen das Gerät nie; der Server kennt nur die Repository-UUID. Ein Ordner wird vor jedem Start erneut geprüft. Höchstens ein offener Lauf je Ordner.
- Berechtigungen von Claude: `--permission-mode dontAsk` mit expliziter Werkzeugliste. Klärungsaufträge: `Read, Glob, Grep` (keine Änderungen). Umsetzungsaufträge: zusätzlich `Edit, Write`. Kein `Bash`, kein Netzwerkwerkzeug, keine MCP-Server (`--strict-mcp-config` mit leerer Konfiguration). Nicht erlaubte Werkzeuge werden automatisch abgelehnt, es gibt keine interaktive Rückfrage. Die Systemanweisung verbietet Commit, Push und Deploy. Die Begrenzung gilt für die Claude-Werkzeuge; die macOS-Sandbox der App-Variante ist noch nicht umgesetzt (der Runner läuft mit den Rechten des Benutzers).
- Keine Secrets in Prompts: Der Prompt enthält nur Titel, Beschreibung, Umfang und Antworten aus der Aufgabe; der Runner fügt keine Tokens, Umgebungsvariablen oder Dateien hinzu, und die Systemanweisung untersagt Secrets in Antworten und Dateien. Aufgabentexte selbst nicht mit Zugangsdaten füllen. Die claude-Anmeldung bleibt im lokalen Claude-Login.
- Lease und Besitz: Jede Schreibaktion trägt die Generation; bei 409/410 oder lokalem Ablauf wird nichts mehr veröffentlicht, der Prozess beendet und `stopped` bestätigt. Ein nicht eindeutig geklärter Prozess (z. B. Absturz zwischen Absicht und Start) blockiert den Ordner, bis ein Mensch `todo-runner release <UUID>` ausführt; es gibt nie einen blinden Neustart.
- Dateirechte: Zustandsordner 0700, Dateien 0600 (Läufe, Allowlist, Config, Logs, Prozessausgabe); Einzelschreiber-Sperre pro Zustandsordner.

## Fehlersuche

Zuerst `todo-runner doctor`, dann `todo-runner status` und `todo-runner logs -n 100` (Datei `<Zustandsordner>/logs/runner.log`, rotiert bei 1 MB, bei Autostart zusätzlich `logs/launchd.*.log`).

| Symptom | Ursache und Abhilfe |
| --- | --- |
| `claude-CLI nicht gefunden` | Pfad mit `TODO_RUNNER_CLAUDE` setzen; im Terminal `claude` starten und anmelden. |
| `Kein Token im Schlüsselbund` | Neu koppeln: `todo-runner pair`. Bei Autostart prüfen, ob der Agent in der Benutzersitzung läuft. |
| `Server nicht erreichbar` | URL, Netz, VPN prüfen. Der Runner wiederholt; nach Ablauf der Lease wird der Lauf als verloren markiert. |
| `Token ungültig oder Gerät widerrufen` | Gerät in der App prüfen, neu koppeln. |
| Aufträge werden nicht angenommen | `doctor`: Binding ohne Ordner (`approve <Ordner> <UUID>`), Ordner nicht les-/schreibbar (macOS Datenschutz: Zugriff für Terminal bzw. Binary unter Systemeinstellungen > Datenschutz & Sicherheit erlauben), anderer Lauf im selben Ordner offen. |
| Lauf „UNKLAR (release nötig)“ | Prüfen, ob noch ein `claude`-Prozess im Ordner läuft (`ps`); falls nicht, `todo-runner release <Lauf-UUID>`. |
| „Ein anderer Runner nutzt diesen Zustandsordner“ | Es läuft schon ein Runner (`launchctl list | grep todo`, `ps`). `status` und `logs` funktionieren trotzdem. |
| Lauf nach Ruhezustand „Interrupted by sleep“ | Erwartetes Verhalten bei erzwungenem Ruhezustand ohne Netz; Auftrag neu freigeben. Für lange Läufe Netzteil anschließen und Deckel offen lassen. |
| Fortschritt erscheint nicht | Mindestabstand 30 s; nur Werkzeugschritte werden gemeldet. Kein Werkzeug genutzt = keine Zwischenmeldung. |
| Lauf endet mit Fehler ohne Ausgabe | `logs` ansehen; `--max-turns` (20) kann bei großen Aufträgen nicht reichen, `--json-schema` verbraucht Turns. |

## Grenzen

Nicht Teil des Runners: Screenshots an Aufgaben, Runner-Steuerung in der Mac-App, macOS-App-Sandbox, Erkennung der Bildschirmsperre (nicht nötig, siehe oben), Benachrichtigung bei Besitzverlust außer über den Auftragsstatus.
