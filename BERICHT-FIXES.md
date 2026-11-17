# Bericht: Review-Fixes 1–9

Stand: 17.11.2026. Repository: Apple-App Todolino, Branch `codex/review-fixes`, Basis `df37e3e`.

Alle neun Befunde wurden erneut am tatsächlichen Code geprüft und bestätigt; keiner wurde verworfen. Reihenfolge: erst die vier hohen, dann die mittleren Befunde. Je Befund wurde zuerst der Regressionstest geschrieben, danach die Implementierung geändert. Jeder Befund hat genau einen deutschen Commit einschließlich lokalem Status-/Arbeitsplan-Checkpoint.

**Keine Builds, Tests oder Netzaufrufe ausgeführt. Kein Push, keine Veröffentlichung, kein Deployment.** Es gibt keine Rot-/Grün-Nachweise und keine Aussage über erfolgreiche Kompilierung. Ausgeführt wurden nur lokale Quelltext-/Git-Durchsicht und `git diff --check` (ohne Befund). Zwölf neue XCTest-Methoden: zehn im App-Testtarget und zwei im Paket. Laufzeit, Geräte, Signierung, Keychain und App-Sandbox prüft der Aufrufer.

## Vorbereitung für den Aufrufer

Alle nachfolgenden Befehle sind vom Repository-Wurzelordner aus auszuführen. Das Xcode-Projekt ist gitignoriert. Vor den App-Tests einmal das neue macOS-Unit-Testtarget aus `project.yml` erzeugen:

```sh
xcodegen generate --spec project.yml
```

Auch dieser Befehl wurde hier nicht ausgeführt. Die App-Tests sind **XCTest**, daher haben ihre `-only-testing`-Selektoren keine `()`. Es wurden keine swift-testing-Tests angelegt; bei solchen Tests im App-Target wäre die vom Auftrag genannte Schreibweise mit `()` erforderlich. Pakettests verwenden `swift test --filter`. Die App-Tests verwenden URLProtocol-Mocks; die Paketregressionen benötigen keinen laufenden Server.

## Befund 1 – Hoch: Serverwechsel während der Anmeldung

Status: **bestätigt und behoben**. Commit: `9262c46621b858f3c8e408766bd045c0b862c4d7`.

Bestätigt: Der bisher gemeinsame TokenStore und die Verwendung des veränderlichen Clients nach dem await ermöglichten den Serverübertritt. Anmeldung und Recovery verwenden jetzt einen festen Client und einen temporären TokenStore. Nur Ergebnisse der aktuellen Sitzungsgeneration werden dauerhaft gespeichert und veröffentlicht. Keychain und Push-Hintergrundaktionen verwenden getrennte Origin-Schlüssel; Start und Capabilities verwerfen verspätete Ergebnisse.

Exakter Testbefehl (nicht ausgeführt):

```sh
xcodebuild test -project Todo.xcodeproj -scheme Todo-macOS -destination 'platform=macOS' -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO -only-testing:Todo-macOS-Tests/ReviewFixTests/testServerSwitchDiscardsDelayedLoginAndScopesToken
```

## Befund 2 – Hoch: Verspätete Synchronisation nach Kontowechsel

Status: **bestätigt und behoben**. Commit: `5eed7438f8c56f8060f2c5836698f1022149feb4`.

Bestätigt: reset allein stoppte laufende Feed-/Mutationsaufrufe nicht. SyncEngine und REST-Outbox werden beim Abmelden dauerhaft invalidiert. Die Engine prüft vor weiterer Anfrage und Persistierung; AppModel prüft Sitzungsgeneration und Engine-Identität vor Veröffentlichung. Nachgelagerte Agenda-/Präferenzabfragen sind ebenfalls abgegrenzt.

Exakter Testbefehl (nicht ausgeführt):

```sh
xcodebuild test -project Todo.xcodeproj -scheme Todo-macOS -destination 'platform=macOS' -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO -only-testing:Todo-macOS-Tests/ReviewFixTests/testInvalidatedSyncCannotPersistOrPublishDelayedFeed
```

## Befund 3 – Hoch: Offline-Arbeit bei abgelaufener Sitzung

Status: **bestätigt und behoben**. Commit: `1d30779c794dcabc8721805a7d165979f50346c3`.

Bestätigt: Die 401-Behandlung rief den löschenden Logout auf. Bei Sitzungsablauf bleiben der bestehende server-/kontogetrennte Sync-Store, die Outbox und Metadaten erhalten. Alte Engines werden dennoch invalidiert. Erneute Anmeldung desselben Kontos öffnet denselben Store. Explizites Abmelden verwirft lokale Arbeit wie bisher.

Exakter Testbefehl (nicht ausgeführt):

```sh
xcodebuild test -project Todo.xcodeproj -scheme Todo-macOS -destination 'platform=macOS' -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO -only-testing:Todo-macOS-Tests/ReviewFixTests/testExpiredSessionPreservesAccountQueueForReauthentication
```

## Befund 4 – Hoch: Versionsgebundene Detailentwürfe

Status: **bestätigt und behoben**. Commit: `262183c8309053b25dcce0da22cc2872fa77d5e1`.

Bestätigt: saveText sendete auch unveränderte Felder und die Engine verwendete die aktuelle bestätigte Version. Der Textentwurf behält jetzt seine Basisversion, sendet nur geänderte Felder und wird bei einer neueren bestätigten Version vor dem Enqueue als Versionskonflikt zurückgewiesen. Konflikte erst nach dem Enqueue behandelt die bestehende Sync-Konfliktwarteschlange. Texte bleiben bei Fehler erhalten.

Exakter Testbefehl (nicht ausgeführt):

```sh
xcodebuild test -project Todo.xcodeproj -scheme Todo-macOS -destination 'platform=macOS' -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO -only-testing:Todo-macOS-Tests/ReviewFixTests/testDetailTextPatchOnlyContainsEditedFields
swift test --package-path TodoCore --skip-update --filter 'SyncEngineTests/testStaleDetailVersionCannotUseNewConfirmedVersion'
```

## Befund 5 – Mittel: Fehler bei dauerhafter Outbox-Speicherung

Status: **bestätigt und behoben**. Commit: `9034a6126154b0f5abdb9a942f9477ffeb8e1657`.

Bestätigt: persist verschluckte Dateifehler. Outbox-Schreiboperationen werfen jetzt Fehler, und fehlgeschlagene Enqueues stellen den vorherigen Speicherzustand wieder her. savePlanning liefert false und zeigt einen lokalisierten Speicherhinweis. Der Planungsentwurf bleibt erhalten. Die Übergabe aus der Sync-Queue entfernt Einträge erst nach erfolgreicher dauerhafter Übernahme. Bestehende Unit- und Live-Testaufrufe sind an throws angepasst.

Exakter Testbefehl (nicht ausgeführt):

```sh
xcodebuild test -project Todo.xcodeproj -scheme Todo-macOS -destination 'platform=macOS' -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO -only-testing:Todo-macOS-Tests/ReviewFixTests/testPlanningSaveReportsPersistenceFailure
swift test --package-path TodoCore --skip-update --filter 'PlanningOutboxTests/testFailedPersistenceThrowsAndPreservesPreviousPlanning'
```

## Befund 6 – Mittel: Eingabe während des initialen Detail-Ladens

Status: **bestätigt und behoben**. Commit: `fbaff5ac16b3c18291536596d751ca0be0e97d0b`.

Bestätigt: Die task-Closure setzte beide Texte nach allen Netzabfragen bedingungslos neu. Jetzt übernimmt sie geladene Werte nur für währenddessen unveränderte Felder. Bei einer Teilbearbeitung bleiben der eingegebene Text und seine ursprüngliche Basisversion erhalten.

Exakter Testbefehl (nicht ausgeführt):

```sh
xcodebuild test -project Todo.xcodeproj -scheme Todo-macOS -destination 'platform=macOS' -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO -only-testing:Todo-macOS-Tests/ReviewFixTests/testInitialDetailLoadPreservesTypedFieldsAndDraftVersion
```

## Befund 7 – Mittel: Weitergetippter Chatentwurf während des Sendens

Status: **bestätigt und behoben**. Commit: `a48c2b0b648d35ba0e3f54d45f46ee432b08b595`.

Bestätigt: Erfolg leerte den aktuellen Composer pauschal. Der Auftrag verwendet einen unveränderlichen Textstand; nur ein weiterhin identischer Entwurf wird nach Erfolg geleert.

Exakter Testbefehl (nicht ausgeführt):

```sh
xcodebuild test -project Todo.xcodeproj -scheme Todo-macOS -destination 'platform=macOS' -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO -only-testing:Todo-macOS-Tests/ReviewFixTests/testChatSuccessKeepsTextTypedWhileSending
```

## Befund 8 – Mittel: Geänderter Chattext nach verlorener Antwort

Status: **bestätigt und behoben**. Commit: `47e14460cf172f165acba2a6b1526a15c9c5fa1a`.

Bestätigt: Der Idempotenzschlüssel überlebte auch eine Änderung des Inhalts. Fehlgeschlagene Aufträge behalten jetzt ihren ursprünglichen Text und Schlüssel getrennt vom Composer. Gleicher Inhalt wiederholt denselben Auftrag; neuer Inhalt erhält einen neuen Schlüssel. Der Test prüft auch die Rückkehr zum ursprünglichen Inhalt.

Exakter Testbefehl (nicht ausgeführt):

```sh
xcodebuild test -project Todo.xcodeproj -scheme Todo-macOS -destination 'platform=macOS' -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO -only-testing:Todo-macOS-Tests/ReviewFixTests/testEditedChatAfterLostResponseUsesNewIdempotencyKey
```

## Befund 9 – Mittel: Dauerhafte Brain-Aufträge und Audio-Aufräumen

Status: **bestätigt und behoben**. Commit: `d45eaa6eea88a332e89f56dd97f1858aa382e5ef`.

Bestätigt: Ausstehende Nachrichten lagen nur im ansichtseigenen Modell. Ein atomar geschriebenes Manifest pro Server/Konto hält jetzt Text oder Audiodauer, clientUUID, Dateireferenz und gegebenenfalls attachmentID fest. Aufnahmen liegen vor dem Versand dauerhaft in Application Support. Wiederöffnung stellt offene Aufträge als wiederholbar fehlgeschlagen her. Bestätigung oder ausdrückliches Verwerfen entfernt den Eintrag und die Aufnahme; beim Öffnen werden unterbrochene Löschungen nachgeholt. Manifest und Audio haben private Dateirechte. Konto- und Servertrennung sowie Versandbestätigung und Verwerfen sind abgedeckt.

Exakter Testbefehl (nicht ausgeführt):

```sh
xcodebuild test -project Todo.xcodeproj -scheme Todo-macOS -destination 'platform=macOS' -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO -only-testing:Todo-macOS-Tests/ReviewFixTests/testBrainPendingMessagesSurviveReopeningAndCleanUpAudio -only-testing:Todo-macOS-Tests/ReviewFixTests/testBrainConfirmedDeliveryRemovesAudioAndManifest
```

## Übergabe und Grenzen

- Änderungen ausschließlich in diesem Apple-Worktree. Keine Backend-, REST-/MCP-Vertrags- oder Server-Datenbankmigration; das Hauptrepository wurde nur gelesen.
- Alte ungebundene Keychain-Tokens werden aus Sicherheitsgründen nicht automatisch einer Origin zugeordnet. Bestehende Installationen müssen sich einmal neu anmelden. Bestehende konto-/serverbezogene Sync-/Outbox-Dateipfade bleiben erhalten; die neue Brain-Warteschlange ist zusätzlich.
- Die Brain-Warteschlange kann vor diesem Fix bereits verlorene Nachrichten oder nicht mehr referenzierte alte Temp-Aufnahmen nicht rekonstruieren. Wiederaufnahme erfolgt ausdrücklich über den vorhandenen Wiederholen-Knopf, kein automatischer Versand beim Öffnen.
- Alle Ausführungsprüfungen offen, insbesondere macOS-Testhost/Signierung, iOS-/macOS-/watchOS-Kompilierung, Keychain auf Gerät sowie reale Netz-/Speicherfehler und Audionutzung. Der bestehende Live-Test wurde nur an die werfende Outbox-API angepasst, nicht ausgeführt.
- `.workspace.local.json` fehlt im Worktree. Die Datei des ursprünglichen Apple-Checkouts enthält veraltete Documents-Pfade; das Hauptrepository wurde unter `~/Development/PhpstormProjects/todo` gefunden. Lokaler SwiftUI-Skill gelesen. Keine Subagenten eingesetzt.
- Keine eigenen Hintergrundjobs gestartet. Das Prozessinventar war durch die Sandbox gesperrt; über bereits laufende fremde Jobs wird keine Aussage getroffen.
- Nächster Schritt: Aufrufer erzeugt das Xcode-Projekt und führt die oben angegebenen Tests sowie die betroffenen Apple-Builds aus. Kein automatischer Push.
