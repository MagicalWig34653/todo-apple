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
- Tap: `kind` (`reminder|question|review|comment|action_request|daily_brief|test`), `taskID`, `projectID`, `subjectID` aus dem Top-Level-userInfo (`TodoCore/Push.swift`, `PushPayload`). Erinnerung/Kommentar: Aufgabe; Rückfrage/Review: Steuerzentrale (Projekt-Steuerzentrale, wenn das Projekt bekannt ist) mit der Aufgabe darüber; `action_request` (Bestätigungsanfrage, `subjectID` = Anfrage) öffnet "Für dich" (`PushLink.forYou(requestID:)`): die Karte der Anfrage wird in den sichtbaren Bereich gescrollt und mit Markenfarbe umrandet (`confirm.card.highlighted`); fehlt `subjectID`, ist es keine gültige UUID oder listet der Feed die Anfrage nach dem Aktualisieren nicht mehr (entschieden, abgelaufen), bleibt es bei "Für dich", ohne Fehler und ohne Rückfall auf die Steuerzentrale; `daily_brief` (ohne IDs) öffnet die Steuerzentrale ohne Aufgabe; `test` und unbekannte Kinds öffnen nichts. Fällt der Link beim Kaltstart an, wird er gemerkt und nach der Anmeldung geöffnet.
- Kategorien/Aktionen: `TODO_REMINDER` (Erledigen, Später), `TODO_QUESTION` (Antworten = App öffnen), `TODO_REVIEW` (Öffnen), `TODO_COMMENT`, `TODO_CONFIRMATION` und `TODO_DAILY_BRIEF` (alle ohne Aktion, Standard-Tap). "Erledigen" läuft über die Sync-Queue, bei nicht gestarteter App per REST mit der gespeicherten Sitzung (Fallback: öffnet die Aufgabe). "Später" plant lokal dieselbe Erinnerung in einer Stunde (nichts geht an den Server).
- Zähler: `aps.badge` vom Server (offene Fragen plus ausstehende Reviews); in der laufenden App hält `refreshCommandSummary` ihn aktuell, wenn "Zähler" aktiv ist.
- Keine Notification Service Extension (`mutable-content` ist gesetzt, die Nachricht ist aber ohne Nachladen vollständig).

## Bündelung (Karte DF163B26)

Benachrichtigungen eines Projekts stapeln sich als eine Gruppe, statt einzeln zu stehen.

- **Gruppe:** Der Server setzt `aps.thread-id` = Projekt-ID (Backend `PushDelivery.swift`, Erinnerung, Rückfrage, Review, Kommentar); iOS stapelt danach selbst. Ohne Projekt (`action_request`, `daily_brief`, `test`) sendet der Server keine Thread-ID, diese Pushes landen im App-Standardstapel (ohne Notification Service Extension nicht änderbar).
- **Lokale Kopie ("Später"):** `PushGrouping.threadIdentifier(for:)` (TodoCore): Thread-ID des Servers, sonst Projekt-ID (Großbuchstaben, wie der Server), sonst `todolino.<kind>`, sonst keine. `NotificationDelegate.snoozeRequest` setzt sie, wenn die Kopie keine hat; die Erinnerung bleibt so im Stapel ihres Projekts.
- **Zusammenfassung:** Jede der sechs Kategorien trägt ein `categorySummaryFormat` ("%u weitere Erinnerungen", "... Rückfragen", "... Reviews", "... Kommentare", "... Bestätigungen", "... Tagesberichte"), Schlüssel `push.summary.*` in `Localizable.xcstrings`, Zuordnung `PushGrouping.summaryFormatKey(category:)`.
- **Nicht umgesetzt:** `summary-arg` (Projektname in der Zusammenfassung) braucht Server oder Notification Service Extension; nicht Teil dieser Karte.
- **Tests:** `PushGroupingTests` (TodoCore, 8 Tests); `PushGroupingUITests` (Simulator, echter `NotificationDelegate` über `TODO_DEBUG_DELIVER_RESPONSE` mit `TODO_DEBUG_DELIVER_ACTION=TODO_SNOOZE`): Thread der "Später"-Kopie mit und ohne Server-Thread, und `summaries=6/6` aus `getNotificationCategories`. Grenze: Der Simulator kann die Benachrichtigungserlaubnis nicht erteilen, die Probe meldet deshalb die gebaute Anfrage, nicht den Systemspeicher; das tatsächliche Stapeln auf dem Sperrbildschirm macht iOS und ist nicht automatisiert geprüft.

## Einstellungen

Kategorien Erinnerungen, Rückfragen, Reviews, Kommentare, Bestätigungen, Tagesbericht (Zuweisungen gibt es serverseitig noch ohne Auslöser, daher nicht in der Oberfläche), "Inhalt anzeigen" (Standard aus: generische Texte ohne Aufgabentitel), "Zähler am App-Symbol". Werte gelten pro Konto, nicht pro Gerät. Systemstatus mit Link in die Systemeinstellungen bei "Nicht erlaubt".

**Bestätigungen und Tagesbericht (Vorschau, Brief freigegeben, noch nicht final).** In derselben Gruppe wie die anderen Kategorien (`NotificationSettingsSections`): "Bestätigungen" (Standard an) und "Tagesbericht" (Standard aus). Nur bei aktivem Tagesbericht erscheint darunter die Auswahl "Uhrzeit" (24 Einträge, nach Ortszeit sortiert, Bezeichnung als Ortszeit im Format des Geräts). Der Server speichert eine UTC-Stunde (`dailyBriefHour`); die Auswahl rechnet mit dem heutigen Offset (`DailyBriefHour.options`), speichert also immer eine ganze UTC-Stunde. Folgen: In Zeitzonen mit halben Stunden erscheinen Einträge wie 13:30; bei Zeitumstellung verschiebt sich die Ortszeit um eine Stunde (die Fußzeile sagt das). Ohne gespeicherten Wert gilt 8 Uhr UTC. Aktualisierung optimistisch wie bei den übrigen Schaltern, bei Fehler Rückfall und derselbe Fehlertext. Ältere Server (Antwort ohne `confirmations`, `daily_brief` und `dailyBriefHour`, `PushPrefs.supportsBriefSettings == false`) blenden beide Schalter und die Uhrzeit aus. Bezeichner für UI-Tests: `push.cat.confirmations`, `push.cat.dailyBrief`, `push.dailyBrief.time`. Bilder: `docs/screenshots/push-einstellungen-apple/`, Aufnahme über `App/UITests/PushSettingsTour.swift`.

## Bestätigungen und Tagesbericht (Vertrag push.yaml 1.1.0)

Stand: nur unsichtbare Grundlage in TodoCore und Kategorie-Registrierung; **keine Oberfläche und keine Einstellungs-Schalter**, die warten auf eine Brief-Freigabe.

- Neue Kinds: `action_request` (Kategorie `TODO_CONFIRMATION`, `subjectID` = Bestätigungsanfrage) und `daily_brief` (Kategorie `TODO_DAILY_BRIEF`, keine IDs). Beide werden von `PushPayload` erkannt und über das vorhandene Link-Mapping zu `.commandCenter(taskID: nil, projectID: nil)`; der Tap-Pfad in `NotificationDelegate` bleibt unverändert. Der Tap auf `action_request` öffnet "Für dich" und die Karte der Anfrage (`AppModel.confirmationFocus`, `FeedView.resolveConfirmationFocus`; Kaltstart über den gemerkten `pendingLink`, Vordergrund über `AppModel.open`). Die Umrandung bleibt, bis entschieden wird oder die Ansicht verlassen wird. Ist die Karte nur über viele Einträge erreichbar, scrollt die Liste nach dem Laden dorthin (die Karten stehen in "Für dich" ganz oben).
- Prefs: `categories.confirmations` (Standard an), `categories.daily_brief` (Standard aus) und `dailyBriefHour` (UTC-Stunde 0 bis 23; `PushPrefs.dailyBriefHour` ist `nil`, wenn der Server nichts meldet). `PushCategory.confirmations` und `.dailyBrief` (JSON-Schlüssel `daily_brief`), `PushPrefsUpdate(dailyBriefHour:)` sendet die Stunde nur, wenn sie gesetzt ist (Teilupdate). Ältere Server ohne die Schlüssel brechen nichts: fehlende Kategorien bekommen die Standardwerte, unbekannte Schlüssel werden ignoriert.
- Grenzen: Die Stunde ist UTC und lässt sich über die API nicht auf "Standard" zurücksetzen (nur auf einen Wert 0 bis 23 setzen). Der Server prüft 0 bis 23 (`invalid_daily_brief_hour`), der Client nicht. Eine Oberfläche müsste die Stunde in Ortszeit umrechnen. Der Tagesbericht enthält nur Zähler, nie Titel, unabhängig von "Inhalt anzeigen".

## Belege je Punkt (Karte D97C4918, 27.11.2026)

Kurzzeichen: **DL** = `App/UITests/PushDeepLinkUITests`, **AC** = `App/UITests/PushAccountUITests` (echte App im Simulator, natives Backend, echter `NotificationDelegate`; nur Apples Teil ist ersetzt: Push-Antwort per `TODO_DEBUG_DELIVER_RESPONSE`, Token per `TODO_DEBUG_APNS_TOKEN` über den echten `AppDelegate`-Callback). **MAC** = `scripts/mac-push-e2e.sh` (echtes Mac-Hauptfenster, unsichtbar). **UT** = `PushTests` in TodoCore. Commits: Fix `952f102`, E2E `9d97628`, große Schrift und "Erledigen" `c9d2c31`; Stand davor schon in `9c615ce`, `ea11306`.

Aufruf: `TODO_UITEST_CONFIRMATIONS=1 scripts/ui-tests.sh -collect-test-diagnostics never -only-testing:Todo-iOS-UITests/PushDeepLinkUITests -only-testing:Todo-iOS-UITests/PushAccountUITests` (Simulator immer über `sim-sperre.py`; iPad: `TODO_UITEST_DEVICE=<UDID>`; Ablehnen: `TEST_RUNNER_TODO_UITEST_PERMISSION=deny` auf frischem Simulator).

### Deep-Links je Push-Art

Jede Art: Kaltstart (Antwort während des Starts, hell) und warm (App steht auf "Suche", dunkel), iPhone und iPad, dazu Mac hell und dunkel.

| Push-Art | Ziel | iPhone / iPad (DL) | Mac (MAC) | Zuordnung (UT) |
|---|---|---|---|---|
| `reminder` | Projektseite, Aufgabe darüber | `testReminderOpensTheTaskInItsProject` | `reminder` | `testResponseActions`, `testBackendPayloadBytesResolveToTaskLink` |
| `comment` | Projektseite, Aufgabe darüber | `testCommentOpensTheTaskInItsProject` | `comment` | `testPayloadParsingAndLinks` |
| `question` | Projekt-Steuerzentrale, Aufgabe darüber | `testQuestionOpensTheProjectCommandCenterWithTheTask` | `question` | `testOtherKindsKeepTheirDestinations` |
| `review` | Projekt-Steuerzentrale, Aufgabe darüber | `testReviewOpensTheProjectCommandCenterWithTheTask` | `review` | `testOtherKindsKeepTheirDestinations` |
| `action_request` | "Für dich", Karte der Anfrage umrandet | `testActionRequestOpensForYouWithTheRequestCard`, `PushNavigationUITests` | `action_request` | `testBackendActionRequestPayloadOpensConfirmationInForYou` |
| `daily_brief` | Steuerzentrale (alle Projekte), keine Aufgabe | `testDailyBriefOpensTheCommandCenterWithoutATask` | `daily_brief` | `testBackendDailyBriefPayloadOpensCommandCenter` |
| `test`, unbekannt | öffnet nichts | nicht im Simulator (nur Zuordnung) | nicht geprüft | `testNewKindsNeverNeedIDsAndUnknownKindsStayNil` |

Weitere Fälle: große Schrift (`testLargeTextReachesTheSameDestinations`, Erinnerung und Rückfrage; iPad zeigt dann ein Sheet), Push zu einem noch nicht synchronisierten Projekt (`testPushForAProjectNotSyncedYetStillOpensIt`), Aktion "Erledigen" bei laufender App (`testDoneActionOfAReminderCompletesTheTaskOnTheServer`), "Später" (`PushGroupingUITests`), "Antworten"/"Öffnen" (`PushResponseUITests.testActionButtonsThatOpenTheApp`).

**Behobene Lücke (`952f102`):** Beim Tap aus der geschlossenen App öffnete sich zwar die Aufgabe, darunter lag aber die falsche Seite (Erinnerung, Kommentar: nicht das Projekt; Rückfrage, Review: nicht die Projekt-Steuerzentrale). Der Link wurde verbraucht, bevor die Projektliste geladen war; dasselbe bei einem gerade erst angelegten Projekt. Jetzt entscheidet `PushLink.readiness`: sofort, warten auf die ersten Daten, oder einmal nachladen (höchstens vier Versuche, danach das allgemeine Ziel). Rot vorher: `PushTests` 6 Fehler (`dc5aca7`), DL auf dem iPhone 6 von 8 rot (Erinnerung, Kommentar, Rückfrage, Review, große Schrift; der Nachlade-Test scheiterte erst am Testdaten-Aufruf und war nach dessen Korrektur ohne Fix rot).

**Behobene Lücke große Schrift (`c9d2c31`):** In der geöffneten Aufgabe standen "erstellt" und "zuletzt geändert" in vier schmalen Spalten und wurden abgeschnitten; bei Bedienungshilfen-Größen stehen sie jetzt untereinander (Prüfung in `testLargeTextReachesTheSameDestinations`).

### Registrierung, Berechtigung, Einstellungen

| Punkt | Beleg (AC) | Lücke |
|---|---|---|
| Kein System-Dialog von selbst; Erklärkarte nur auf Wunsch, "Nicht jetzt" bleibt | `test1PrimerCardAsksOnlyOnRequestAndStaysDismissed` | - |
| Älterer Server (404): keine Push-Bedienelemente, keine Registrierung | `test2OlderServerHidesPushControls`, UT `testOlderServerAnswers404` | - |
| Erlauben: Dialog erst nach Tap, Status "Erlaubt", Gerät beim Server (`ios`, `sandbox`, `de.linolaske.todo`) | `test3PermissionRegistrationAndSignOut` | Token von Apple nur auf dem Gerät |
| Ablehnen: "Nicht erlaubt", Knopf in die Systemeinstellungen, keine Registrierung | `test3…` mit `TODO_UITEST_PERMISSION=deny` | Sprung in die Systemeinstellungen nicht ausgelöst |
| Einmal je Sitzung und Token, erneut beim nächsten Start, ein Gerät je Token | `test3…` | Konto-Wechsel nicht in der Oberfläche |
| Abmelden widerruft das Gerät (204, nicht mehr gelistet) | `test3…` | - |
| Alle Schalter (6 Anlässe, "Inhalt anzeigen", "Zähler") speichern und zurück; Fehler: Schalter springt zurück mit Hinweis | `test4SettingsSwitchesReachTheServer` | Zähler am App-Symbol selbst nur auf dem Gerät |
| Tagesbericht-Uhrzeit bleibt nach Neustart | `PushBriefPersistenceUITests` | - |

### Offene Grenzen

- Echte Zustellung über APNs, echtes Token, echtes Antippen eines Banners, Stapeln auf dem Sperrbildschirm: nur Gerät (Anleitung unten). `PushOpenUITests` überspringt ohne Banner.
- `environment` = `production` entsteht nur im Release-Build (`#if DEBUG`), nicht automatisch geprüft.
- Mac: nur die Navigation im unsichtbaren Fenster. Die Aufnahme zeigt die rechte Aufgaben-Spalte nicht (dort zählt `model.path` aus `report.json`) und in dunkel eine helle Seitenleiste (bekannt aus `mac-window-e2e.sh`). Berechtigung und Registrierung am Mac, Kaltstart aus einer Mac-Mitteilung: nicht geprüft.
- "Erledigen" aus der geschlossenen App (REST mit gespeicherter Sitzung): nicht automatisiert (die Debug-Sitzung liegt nicht im Schlüsselbund).

## Gerätetest (nur Lino, nach dem nächsten TestFlight-Build mit `952f102`)

1. iPhone: neuen Build installieren, anmelden. Es darf **kein** Mitteilungs-Dialog von selbst kommen.
2. Einstellungen > Benachrichtigungen > "Benachrichtigungen aktivieren" > "Erlauben": Status "Erlaubt", kein Warnhinweis darunter.
3. Todolino im App-Umschalter ganz schließen, dann einen Agenten auf einer Karte eine Rückfrage stellen lassen.
4. Die Mitteilung antippen: Die Karte ist offen; nach "Fertig" steht darunter die Steuerzentrale **dieses** Projekts.
5. "ok" oder Bildschirmfoto plus den Schritt, der abweicht, als Kommentar auf Karte D97C4918.

## Fehlersuche

- **Keine Zustellung, Einstellungen zeigen "Erlaubt":** Server-Hinweis "Push noch nicht aktiviert" sichtbar? Dann `APNS_ENABLED=true` und Schlüssel fehlen (PUSH-EINRICHTUNG im Hauptrepo). Sonst auf dem Server `App push-test <konto-id> --yes` und das Ergebnis je Gerät lesen.
- **`BadDeviceToken` / `DeviceTokenNotForTopic` im Serverlog:** Sandbox-Token an Production-Endpunkt (oder umgekehrt) bzw. falsche Bundle-ID. Debug-Builds registrieren `sandbox`, TestFlight `production`.
- **"Das Gerät konnte sich nicht für Push registrieren":** `didFailToRegisterForRemoteNotificationsWithError`. Häufig: App-ID `de.linolaske.todo` hat die Push-Capability im Developer Portal noch nicht, das Provisioning-Profil enthält kein `aps-environment` (Xcode: Signing & Capabilities neu laden / automatisches Signieren aktualisiert das Profil), oder der Simulator hat kein Token.
- **Nach Neuinstallation doppelte Geräte:** harmlos, der Server hält höchstens 20 aktive je Konto und widerruft ungültige Tokens bei APNs-Antwort 410.
- **Tap öffnet nichts:** Payload ohne `taskID`/`projectID` (Test-Nachricht) ist erwartet.

## Tests

`App/UITests/PushDeepLinkUITests`, `App/UITests/PushAccountUITests`, `scripts/mac-push-e2e.sh` (siehe "Belege je Punkt") und `TodoCore/Tests/TodoCoreTests/PushTests.swift` (Mock: Request-Formen, Decoding, 404 bei älteren Servern, Deep-Link- und Aktions-Mapping, Tolerance gegen fremde Payloads, neue Prefs-Schlüssel mit/ohne Server-Unterstützung, Backend-Payloads von `action_request` und `daily_brief`), Live: `LiveEtappe2Tests.testLivePushDevicesAndPrefs` (nur mit `TEST_RUNNER_TODO_LIVE_BASE_URL`). Echte Zustellung über APNs ist nicht automatisiert prüfbar (braucht Schlüssel und Gerät).
