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
- Tap: `kind` (`reminder|question|review|comment|action_request|daily_brief|test`), `taskID`, `projectID`, `subjectID` aus dem Top-Level-userInfo (`TodoCore/Push.swift`, `PushPayload`). Erinnerung/Kommentar: Aufgabe; Rückfrage/Review: Steuerzentrale (Projekt-Steuerzentrale, wenn das Projekt bekannt ist) mit der Aufgabe darüber; `action_request` (Bestätigungsanfrage, `subjectID` = Anfrage, ohne `taskID`/`projectID`) und `daily_brief` (ohne IDs) öffnen die Steuerzentrale ohne Aufgabe; `test` und unbekannte Kinds öffnen nichts. Fällt der Link beim Kaltstart an, wird er gemerkt und nach der Anmeldung geöffnet.
- Kategorien/Aktionen: `TODO_REMINDER` (Erledigen, Später), `TODO_QUESTION` (Antworten = App öffnen), `TODO_REVIEW` (Öffnen), `TODO_COMMENT`, `TODO_CONFIRMATION` und `TODO_DAILY_BRIEF` (alle ohne Aktion, Standard-Tap). "Erledigen" läuft über die Sync-Queue, bei nicht gestarteter App per REST mit der gespeicherten Sitzung (Fallback: öffnet die Aufgabe). "Später" plant lokal dieselbe Erinnerung in einer Stunde (nichts geht an den Server).
- Zähler: `aps.badge` vom Server (offene Fragen plus ausstehende Reviews); in der laufenden App hält `refreshCommandSummary` ihn aktuell, wenn "Zähler" aktiv ist.
- Keine Notification Service Extension (`mutable-content` ist gesetzt, die Nachricht ist aber ohne Nachladen vollständig).

## Einstellungen

Kategorien Erinnerungen, Rückfragen, Reviews, Kommentare, Bestätigungen, Tagesbericht (Zuweisungen gibt es serverseitig noch ohne Auslöser, daher nicht in der Oberfläche), "Inhalt anzeigen" (Standard aus: generische Texte ohne Aufgabentitel), "Zähler am App-Symbol". Werte gelten pro Konto, nicht pro Gerät. Systemstatus mit Link in die Systemeinstellungen bei "Nicht erlaubt".

**Bestätigungen und Tagesbericht (Vorschau, Brief freigegeben, noch nicht final).** In derselben Gruppe wie die anderen Kategorien (`NotificationSettingsSections`): "Bestätigungen" (Standard an) und "Tagesbericht" (Standard aus). Nur bei aktivem Tagesbericht erscheint darunter die Auswahl "Uhrzeit" (24 Einträge, nach Ortszeit sortiert, Bezeichnung als Ortszeit im Format des Geräts). Der Server speichert eine UTC-Stunde (`dailyBriefHour`); die Auswahl rechnet mit dem heutigen Offset (`DailyBriefHour.options`), speichert also immer eine ganze UTC-Stunde. Folgen: In Zeitzonen mit halben Stunden erscheinen Einträge wie 13:30; bei Zeitumstellung verschiebt sich die Ortszeit um eine Stunde (die Fußzeile sagt das). Ohne gespeicherten Wert gilt 8 Uhr UTC. Aktualisierung optimistisch wie bei den übrigen Schaltern, bei Fehler Rückfall und derselbe Fehlertext. Ältere Server (Antwort ohne `confirmations`, `daily_brief` und `dailyBriefHour`, `PushPrefs.supportsBriefSettings == false`) blenden beide Schalter und die Uhrzeit aus. Bezeichner für UI-Tests: `push.cat.confirmations`, `push.cat.dailyBrief`, `push.dailyBrief.time`. Bilder: `docs/screenshots/push-einstellungen-apple/`, Aufnahme über `App/UITests/PushSettingsTour.swift`.

## Bestätigungen und Tagesbericht (Vertrag push.yaml 1.1.0)

Stand: nur unsichtbare Grundlage in TodoCore und Kategorie-Registrierung; **keine Oberfläche und keine Einstellungs-Schalter**, die warten auf eine Brief-Freigabe.

- Neue Kinds: `action_request` (Kategorie `TODO_CONFIRMATION`, `subjectID` = Bestätigungsanfrage) und `daily_brief` (Kategorie `TODO_DAILY_BRIEF`, keine IDs). Beide werden von `PushPayload` erkannt und über das vorhandene Link-Mapping zu `.commandCenter(taskID: nil, projectID: nil)`; der Tap-Pfad in `NotificationDelegate` bleibt unverändert. Achtung: Die Bestätigungskarten (`ConfirmationCard`) liegen in der App derzeit in "Für dich" (`FeedView`), nicht in der Steuerzentrale; der Tap landet also bewusst (Vorgabe) in der Steuerzentrale, nicht direkt bei der Karte. `subjectID` wird geparst, aber noch nicht zum Anspringen genutzt. Ein Sprung nach "Für dich" bräuchte einen eigenen `PushLink`-Fall und Auswahllogik in `AppModel.open`; das ist Teil der ausstehenden Brief-Freigabe.
- Prefs: `categories.confirmations` (Standard an), `categories.daily_brief` (Standard aus) und `dailyBriefHour` (UTC-Stunde 0 bis 23; `PushPrefs.dailyBriefHour` ist `nil`, wenn der Server nichts meldet). `PushCategory.confirmations` und `.dailyBrief` (JSON-Schlüssel `daily_brief`), `PushPrefsUpdate(dailyBriefHour:)` sendet die Stunde nur, wenn sie gesetzt ist (Teilupdate). Ältere Server ohne die Schlüssel brechen nichts: fehlende Kategorien bekommen die Standardwerte, unbekannte Schlüssel werden ignoriert.
- Grenzen: Die Stunde ist UTC und lässt sich über die API nicht auf "Standard" zurücksetzen (nur auf einen Wert 0 bis 23 setzen). Der Server prüft 0 bis 23 (`invalid_daily_brief_hour`), der Client nicht. Eine Oberfläche müsste die Stunde in Ortszeit umrechnen. Der Tagesbericht enthält nur Zähler, nie Titel, unabhängig von "Inhalt anzeigen".

## Fehlersuche

- **Keine Zustellung, Einstellungen zeigen "Erlaubt":** Server-Hinweis "Push noch nicht aktiviert" sichtbar? Dann `APNS_ENABLED=true` und Schlüssel fehlen (PUSH-EINRICHTUNG im Hauptrepo). Sonst auf dem Server `App push-test <konto-id> --yes` und das Ergebnis je Gerät lesen.
- **`BadDeviceToken` / `DeviceTokenNotForTopic` im Serverlog:** Sandbox-Token an Production-Endpunkt (oder umgekehrt) bzw. falsche Bundle-ID. Debug-Builds registrieren `sandbox`, TestFlight `production`.
- **"Das Gerät konnte sich nicht für Push registrieren":** `didFailToRegisterForRemoteNotificationsWithError`. Häufig: App-ID `de.linolaske.todo` hat die Push-Capability im Developer Portal noch nicht, das Provisioning-Profil enthält kein `aps-environment` (Xcode: Signing & Capabilities neu laden / automatisches Signieren aktualisiert das Profil), oder der Simulator hat kein Token.
- **Nach Neuinstallation doppelte Geräte:** harmlos, der Server hält höchstens 20 aktive je Konto und widerruft ungültige Tokens bei APNs-Antwort 410.
- **Tap öffnet nichts:** Payload ohne `taskID`/`projectID` (Test-Nachricht) ist erwartet.

## Tests

`TodoCore/Tests/TodoCoreTests/PushTests.swift` (Mock: Request-Formen, Decoding, 404 bei älteren Servern, Deep-Link- und Aktions-Mapping, Tolerance gegen fremde Payloads, neue Prefs-Schlüssel mit/ohne Server-Unterstützung, Backend-Payloads von `action_request` und `daily_brief`), Live: `LiveEtappe2Tests.testLivePushDevicesAndPrefs` (nur mit `TEST_RUNNER_TODO_LIVE_BASE_URL`). Echte Zustellung über APNs ist nicht automatisiert prüfbar (braucht Schlüssel und Gerät).
