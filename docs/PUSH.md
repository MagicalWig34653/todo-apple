# Push-Benachrichtigungen (APNs) in der Apple-App

Server-Seite: Hauptrepo `docs/adr/0021-apns-push.md`, `contracts/push.yaml`, `docs/PUSH-EINRICHTUNG.md`. Hier steht nur, wie die App damit umgeht.

## Ablauf

1. **Berechtigung nie beim ersten Start.** Der System-Dialog erscheint nur nach einer bewussten Handlung: Einstellungen (Konto, auf dem Mac auch Cmd+,) > Benachrichtigungen > "Benachrichtigungen aktivieren", oder über die Erklärkarte oben in der Steuerzentrale (erscheint nur, wenn offene Rückfragen/Reviews existieren und noch nicht gefragt wurde; "Nicht jetzt" blendet sie dauerhaft aus).
2. **Token.** Ist die Berechtigung vorhanden, ruft die App bei jedem Start/Vordergrund `registerForRemoteNotifications()` auf. Das Token (Hex, klein) landet in `PushCoordinator.didRegister`.
3. **Registrierung.** `POST /v1/push/devices` (idempotent je Token) mit Plattform (`ios`/`macos`), Umgebung, Bundle-ID (`de.linolaske.todo`), App-Version, Locale. Bei Start, neuem Token, Konto-Wechsel und Rückkehr in den Vordergrund (pro Sitzung und Token nur einmal gesendet). Die Geräte-ID wird je Konto lokal gemerkt.
4. **Abmeldung.** `AppModel.logout()` widerruft das Gerät (`DELETE /v1/push/devices/{id}`) vor dem Beenden der Sitzung und setzt den Zähler zurück.
5. **Ältere Server.** Antwortet `GET /v1/me/push-prefs` oder die Registrierung mit 404, blendet die App alle Push-Bedienelemente aus und fragt nicht weiter (`serverSupport == .unavailable`). `/health/ready` meldet `push.enabled`; steht es auf `false`, zeigt die Einstellung einen Hinweis (Registrierung ist trotzdem möglich).

## Sandbox oder Production

| Build | `aps-environment` | Registrierung `environment` |
|---|---|---|
| Debug (aus Xcode auf Gerät) | `development` | `sandbox` |
| Release (Archiv, TestFlight, App Store) | `production` | `production` |

Umgesetzt über `APS_ENVIRONMENT` in `App/Config/Base.xcconfig` (Debug `development`, Release `production`) und die Entitlements `Todo.entitlements` (iOS, Schlüssel `aps-environment`) sowie `Todo-macOS.entitlements` (Schlüssel `com.apple.developer.aps-environment`). Im Code entscheidet `#if DEBUG` (sandbox sonst production). Der Server sendet je Gerät an `api.sandbox.push.apple.com` bzw. `api.push.apple.com`; der APNs-Schlüssel (.p8) gilt für beide.

## Eingehende Benachrichtigungen

- Vordergrund: Banner, Ton, Zähler; zusätzlich Sync und Aktualisierung der Steuerzentrale-Zahlen.
- Tap: `kind` (`reminder|question|review|comment|test`), `taskID`, `projectID`, `subjectID` aus dem Top-Level-userInfo (`TodoCore/Push.swift`, `PushPayload`). Erinnerung/Kommentar: Aufgabe; Rückfrage/Review: Steuerzentrale (Projekt-Steuerzentrale, wenn das Projekt bekannt ist) mit der Aufgabe darüber; `test` öffnet nichts. Fällt der Link beim Kaltstart an, wird er gemerkt und nach der Anmeldung geöffnet.
- Kategorien/Aktionen: `TODO_REMINDER` (Erledigen, Später), `TODO_QUESTION` (Antworten = App öffnen), `TODO_REVIEW` (Öffnen), `TODO_COMMENT` (ohne Aktion). "Erledigen" läuft über die Sync-Queue, bei nicht gestarteter App per REST mit der gespeicherten Sitzung (Fallback: öffnet die Aufgabe). "Später" plant lokal dieselbe Erinnerung in einer Stunde (nichts geht an den Server).
- Zähler: `aps.badge` vom Server (offene Fragen plus ausstehende Reviews); in der laufenden App hält `refreshCommandSummary` ihn aktuell, wenn "Zähler" aktiv ist.
- Keine Notification Service Extension (`mutable-content` ist gesetzt, die Nachricht ist aber ohne Nachladen vollständig).

## Einstellungen

Kategorien Erinnerungen, Rückfragen, Reviews, Kommentare (Zuweisungen gibt es serverseitig noch ohne Auslöser, daher nicht in der Oberfläche), "Inhalt anzeigen" (Standard aus: generische Texte ohne Aufgabentitel), "Zähler am App-Symbol". Werte gelten pro Konto, nicht pro Gerät. Systemstatus mit Link in die Systemeinstellungen bei "Nicht erlaubt".

## Fehlersuche

- **Keine Zustellung, Einstellungen zeigen "Erlaubt":** Server-Hinweis "Push noch nicht aktiviert" sichtbar? Dann `APNS_ENABLED=true` und Schlüssel fehlen (PUSH-EINRICHTUNG im Hauptrepo). Sonst auf dem Server `App push-test <konto-id> --yes` und das Ergebnis je Gerät lesen.
- **`BadDeviceToken` / `DeviceTokenNotForTopic` im Serverlog:** Sandbox-Token an Production-Endpunkt (oder umgekehrt) bzw. falsche Bundle-ID. Debug-Builds registrieren `sandbox`, TestFlight `production`.
- **"Das Gerät konnte sich nicht für Push registrieren":** `didFailToRegisterForRemoteNotificationsWithError`. Häufig: App-ID `de.linolaske.todo` hat die Push-Capability im Developer Portal noch nicht, das Provisioning-Profil enthält kein `aps-environment` (Xcode: Signing & Capabilities neu laden / automatisches Signieren aktualisiert das Profil), oder der Simulator hat kein Token.
- **Nach Neuinstallation doppelte Geräte:** harmlos, der Server hält höchstens 20 aktive je Konto und widerruft ungültige Tokens bei APNs-Antwort 410.
- **Tap öffnet nichts:** Payload ohne `taskID`/`projectID` (Test-Nachricht) ist erwartet.

## Tests

`TodoCore/Tests/TodoCoreTests/PushTests.swift` (Mock: Request-Formen, Decoding, 404 bei älteren Servern, Deep-Link- und Aktions-Mapping, Tolerance gegen fremde Payloads), Live: `LiveEtappe2Tests.testLivePushDevicesAndPrefs` (nur mit `TEST_RUNNER_TODO_LIVE_BASE_URL`). Echte Zustellung über APNs ist nicht automatisiert prüfbar (braucht Schlüssel und Gerät).
