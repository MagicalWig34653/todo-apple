# Absturz beim Öffnen einer Benachrichtigung (Todolino-Karte 68AB3453)

Stand 23.11.2026. Quelle: TestFlight-Absturzmeldungen von Lino (`asc testflight crashes list --app 6827512177`), iPhone18,1, iOS 27.2.

| Meldung (UTC) | Kommentar | Build | Crash-Log |
|---|---|---|---|
| 07.11.2026 09:18 | „Beim öffnen einer Benachrichtigung“ | 0.1.0 (2610311632) | `docs/crash-logs/2026-11-07-build-2610311632-benachrichtigung.crash` |
| 11.11.2026 19:31 | „Beim öffnen einer Benachrichtigung“ | 0.1.0 (2611081645) | `docs/crash-logs/2026-11-11-build-2611081645-benachrichtigung.crash` |
| 15.11.2026 20:14 | (leer) | unbekannt | nicht abrufbar (`betaCrashLogs` fehlt, Apple liefert es nicht mehr) |

Die Logs ließen sich mit `asc testflight crashes log --submission-id <ID>` abrufen (nur für die ersten zwei).

## Ursache (belegt)

Beide Logs: `EXC_CRASH (SIGABRT)`, `NSAssertionHandler handleFailureInMethod` aus `-[UIApplication _performBlockAfterCATransactionCommitSynchronizes:]` (UIKit verlangt den Main-Thread), aufgerufen aus `-[UIApplication _updateSnapshotAndStateRestorationWithAction:windowScene:]` direkt unter `@objc closure #1 in NotificationDelegate.userNotificationCenter(_:didReceive:)` und `completeTaskWithClosure` (Swift Concurrency). Der Aufruf liegt auf einem Thread des Cooperative-Pools (Log 1: Thread 3, Log 2: Thread 6), nicht auf dem Main-Thread.

Mechanismus: Die `async`-Variante von `didReceive` (und `willPresent`) in dem nicht auf den MainActor isolierten `NotificationDelegate` ruft UIKits Completion-Handler aus dem Compiler-Thunk auf dem Cooperative-Pool auf. UIKit assertiert dort den Main-Thread. Jeder Tap auf eine Benachrichtigung, der die App öffnet, konnte so abstürzen (Erinnerung, Frage, Review gleichermaßen: der Pfad ist derselbe).

## Behebung

Commit `ea11306` (12.11.2026, auf `origin/main`): Completion-Handler-Varianten statt `async`, der Handler läuft immer auf dem MainActor (`App/Shared/PushDelegate.swift`). Beide Log-Builds (2610311632, 2611081645) und 2611121259 liegen vor dem Fix.

Offen: Der Absturz vom 15.11. (Build vermutlich 2611130729 oder 2611131302, beide nach dem Fix) hat kein abrufbares Log. Ob er derselbe war, lässt sich nicht belegen. Der Build der Karte (siehe `docs/TESTFLIGHT.md`) soll auf dem Gerät gegengeprüft werden; kommt wieder eine Meldung, mit `asc testflight crashes log` sofort das Log sichern.

## Tests (Öffnen-Pfad)

`App/UITests/PushResponseUITests.swift` ruft den echten `NotificationDelegate` aus einer Hintergrund-Queue auf (DEBUG-Hook `TODO_DEBUG_DELIVER_RESPONSE`, Payload im Backend-Format) und prüft per `dispatchPrecondition(.onQueue(.main))`, dass der Handler auf der Main-Queue läuft:

- Erinnerung, Frage, Review je kalt (während des Starts) und warm (UI steht): `testTapColdStartForEveryKind`, `testTapWarmStartForEveryKind`
- Aktionsknöpfe „Antworten“ (Frage) und „Öffnen“ (Review), kalt und warm: `testActionButtonsThatOpenTheApp` (`TODO_DEBUG_DELIVER_ACTION`)
- bestehend: `testDelegateCompletionOnMainQueueColdStart`, `...WarmStart`, `testDidReceiveCompletionOnMainQueue`

Rot vor dem Fix: gegen den Stand von `ea11306^` (alter `async`-Delegate, Wegwerf-Worktree) scheitern alle 6 Tests mit „de.linolaske.todo crashed“.
