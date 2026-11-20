# Kalender (Apple) – Regeln, Endpunkte, Schreibweg

Karte 8CECAD24. Vorlage: ADR 0033 (Hauptrepo `docs/adr/0033-kalender-geplanter-start-und-waechter.md`, Abschnitt 3), PWA `web/src/lib/calendar.ts`. Verträge: `contracts/planning-ext.yaml` 1.2.0, `contracts/sync.yaml` 1.5.0. Stand: Phase 2 (Schreiben: Ziehen, Editor, Entplanen, Rollback, Offline-Queue, Live-Aktualisierung; Ende-zu-Ende gegen das native Backend).

## Endpunkte (TodoCore `Schedule.swift`)
- `APIClient.schedule(from:to:projectID:limit:)` = `GET /v1/planning/schedule` (Fenster `[from, to)`, höchstens 62 Tage, `limit` 1 bis 500, `ScheduleResponse.truncated`). Eintrag `ScheduleEntry` mit `version`, `plannedAt/Minutes/AllDay`, `dueAt`, `canEdit`, `autoStart`, `repositoryKey`, `conflicts`.
- `APIClient.unscheduled(projectID:limit:)` = `GET /v1/planning/unscheduled` (Seitenleiste "Ohne Termin"; liefert `PlanningTask`, keine Rolle, deshalb `ScheduleEntry(unscheduled:canEdit:)`).
- `APIClient.updateSchedule(taskID:version:_ patch:)` = `PATCH /v1/tasks/{id}/schedule`. Body: `version` plus nur gesetzte Schlüssel (`SchedulePatch`: `FieldChange.keep/.set/.clear`; `null` löscht). `dueAt` ist kein Teil des Patches.
- Fehler als `ScheduleError`: `versionConflict`, `taskDone`, `invalidPlannedMinutes`, `allDayRequiresPlannedAt`, `recurrenceRequiresDate`, `invalidSchedule`, `readOnly` (403), `notFound`, `invalidWindow`, `windowTooLarge`, `invalidLimit`, `rateLimited`, sonst `.other(APIError)` (401, Transport bleiben unterscheidbar).

## Planungsfelder (`PlanningData`, additiv)
`plannedMinutes` (Int?), `plannedAllDay` (Standard false), `autoStart` (Standard false), `autoStartedAt` (Date?). Alte Server liefern nichts davon: Standardwerte. Ein `PUT` sendet `plannedMinutes` nur wenn gesetzt (Schlüssel fehlt = Server behält, nie `null`), `plannedAllDay` immer; `autoStart`/`autoStartedAt` nie (nur `PUT /v1/tasks/{id}/auto-start`). Wer geladene Planung ändert und zurückschickt (Detailansicht, Outbox, Feed/SQLite-Store über `Codable`), verliert Dauer und Ganztägig nicht.

## Regeln (TodoCore `CalendarPlanning.swift`, ohne UI, `Calendar` als Parameter)
- Einrasten 15 Minuten (`CalendarRules.snap`, 0 bis 23:45), Standarddauer 30 Minuten, kleinster Block 15 Minuten.
- Anzeige in Ortszeit des Geräts (PWA: Europe/Berlin). Fenster `CalendarWindow.day/week` richten sich nach `Calendar.firstWeekday`, beginnen an lokalen Mitternächten (Sommerzeit-Tage mit 23/25 Stunden getestet). Minuten eines Tages sind Wanduhrminuten.
- `CalendarLayout`: Einträge je Tag (ganztägig, zeitlich, Fristen), überlappende Blöcke nebeneinander (Cluster teilen die größte Spaltenzahl), Block über Mitternacht erscheint an beiden Tagen.
- Konflikte (`CalendarConflicts`), nur anzeigen: `after_due` (lokal neu berechnet), Vorgänger später/offen (wie vom Server), Überschneidung gleicher `repositoryKey` (lokal, zusätzlich zum Serverhinweis; erledigte, ganztägige und ungebundene Karten ignoriert).
- Drop (`CalendarDrop.decide`): Seitenleiste -> Raster setzt Start; Raster -> Raster verschiebt Start, Dauer bleibt; -> Tageskopf = ganztägig am Tagesbeginn; Ganztägig -> Raster zählt die Drop-Zeit (`plannedAllDay: false`); -> Seitenleiste löscht `plannedAt` (Server löscht Dauer/Ganztägig mit), aber bei Wiederholung ohne `dueAt` `refused(.recurrenceNeedsDate)`. Nur `canEdit` und nicht erledigt ziehbar (`refused(.readOnly/.done)`). Gleiche Position = `noChange`.
- Optimistik: `SchedulePatch.applied(to:)` (Serverregeln), `SchedulePatch.inverse(of:)` für Rollback bei 409/Fehler (danach neu laden) und Rückgängig.

## Online-PATCH oder Sync-Queue (Entscheidung, umgesetzt)
- Online immer `PATCH .../schedule` (Teilschreibweg mit Version, genaue Fehler). `CalendarModel.submit`: optimistisch anzeigen, `updateSchedule(version:)`, bei Erfolg die Serverantwort (neue Version) übernehmen und still neu laden (Marken von Server); bei **jedem** Fehler Rollback (`SchedulePatch.inverse` bzw. alter Eintrag), Neuladen des Plans und eine deutsche Meldung (`calendar.notice.*`: 409, erledigt, nur Lesen, Wiederholung ohne Frist, Dauer, Ganztägig ohne Start, nicht gefunden). Pro Karte höchstens ein Schreibvorgang gleichzeitig (`busy`, sonst Version veraltet).
- Kein Netz (`APIError.transport`): `ScheduleWriteRoute` entscheidet; `SyncEngine.setSchedule` stellt `task.planning` (sync 1.5.0, Vollersatz) aus der aktuellen Planung der Karte inklusive früherer Queue-Einträge zusammen und sendet immer `plannedMinutes`/`plannedAllDay` mit (`SyncMutation.schedule`). Ohne Start sendet es keine Dauer und `plannedAllDay=false` (der Server löscht beides ohnehin). Eine `null`-Dauer lässt sich nicht ausdrücken (`ScheduleError.notAvailableOffline`, Hinweis, Rollback). Die Karte zeigt bis zum Senden die Marke "Wird gesendet" und den Hinweis "Ohne Verbindung gespeichert".
- Reconnect: die Queue sendet beim Sync; nach `unsentChanges` 0 lädt der Kalender neu. Ein 409 beim Replay wird für Kalender-Bearbeitungen **nicht** still wiederholt (`SyncMutation.isScheduleEdit`): Status `conflict`, die Karte zeigt den Serverstand, der vorhandene Sync-Dialog ("Meine Änderung behalten / Serverstand übernehmen") entscheidet; "behalten" sendet auf der neuen Version. Gewöhnliche Planungsbearbeitungen (Frist, Priorität) behalten den einmaligen stillen Wiederholungsversuch. Eine gewöhnliche Planungsbearbeitung (1.4.0-Draht) lässt Dauer/Ganztägig weg, der Server behält sie; die lokale Ansicht (`metaOverlay`) auch.
- Die REST-Outbox (`PlanningOutbox`) bleibt die Brücke für Server vor 1.4.0 unverändert.

## Rolle der Seitenleistenkarten
`/v1/planning/unscheduled` liefert keine Rolle. `CalendarModel.load` nimmt `canEdit` von Schedule-Einträgen desselben Projekts und fragt sonst `GET /v1/projects/{id}/visibility` (Rolle >= edit); unbekannt oder Fehler = **nicht ziehbar** (konservativ, der Server entscheidet ohnehin mit 403). Live bestätigt: Rolle `read` liefert `canEdit=false` und beim Schreiben `403`.

## Bedienung
- iPad/Mac: Karten (Raster, Ganztägig-Zeile, Seitenleiste) sind `draggable` (nur `canDrag`), Spalten, Tageskopf, Ganztägig-Zeile und Seitenleiste sind `dropDestination` (`CalendarDropZone`, Ziel aus der Drop-Position, Einrasten 15 Minuten). Tippen/Klick öffnet das Detail (voller Titel, Projekt, Start, Dauer, Frist, Auto-Start nur als Anzeige, Marken). Kontextmenü und VoiceOver-Aktionen: Details, "Start und Dauer …", "Entplanen".
- iPhone: Tippen auf die Karte öffnet das Detail, langes Drücken das Menü ("Start und Dauer …" = Editor `ScheduleEditing`, "Entplanen"). Editor: Ganztägig, Start, Dauer in 15-Minuten-Schritten; nur geänderte Felder werden gesendet, Standarddauer 30 Minuten wird nicht als Wert gesendet.
- Auto-Start: nur Anzeige (Marke, Detailzeile), kein Umschalten. `dueAt` wird nirgends geschrieben (`SchedulePatch` hat keinen Schlüssel dafür).
- Live: `LiveHub.subscribe` lädt den Plan bei Änderungen am Server nach; nach einem Reconnect lädt der Kalender neu.

## UI (Phase 1: nur Ansicht, Beispieldaten in Vorschauen)
- Einstieg: Seitenleiste "Planen" (iPad/Mac), Cmd-8, iPhone: Schaltfläche "Kalender" in der Werkzeugleiste von "Planen" (Tab-Struktur und Heute/Anstehend/Eingang unverändert).
- iPhone und alle Layouts ab Accessibility-Textgröße: Kopf mit Wochenzeile, Datum, Wochenstreifen, Tageskarten mit Uhrzeit/Dauer/Marken, "Ohne Termin" als Blatt. iPad/Mac: Wochenraster (15-Minuten-Linien, Ganztägig-Zeile, Fristmarken, Jetzt-Linie) mit Seitenleiste; zu schmal: Blatt statt Leiste, noch schmaler: Tagesliste (`ViewThatFits`).
- Marken immer mit Symbol und Text (Frist, Konflikte, Auto-Start nur als Anzeige, erledigt, nur lesen).
- Debug: `TODO_DEBUG_CALENDAR_PREVIEW=1` (Beispieldaten, kein Server), `TODO_DEBUG_SELECT=calendar`. Aufnahmen: `App/UITests/CalendarPreviewTour.swift` nach `docs/screenshots/kalender-apple-vorschau/`.

## Bilder
`docs/screenshots/kalender-apple-vorschau/` (Beispieldaten, `CalendarPreviewTour`, eigener Simulator; Helligkeit geprüft: hell Mittel >= 209, dunkel <= 44):
- iPhone: `tagesliste-hell|dunkel`, `tagesliste-hell-accessibility3` und `tagesliste-karten-hell-accessibility3` (Wochenstreifen bei großer Schrift mittig, ganze Datumswerte erreichbar), `ohne-termin-blatt-hell`, `detail-karte-hell` (voller Titel, Projekt, Start, Dauer, Frist, Auto-Start nur Anzeige), `start-und-dauer-hell`, `rollback-hinweis-hell` (409, Karte zurück, Hinweis).
- iPad: `wochenraster-hell|dunkel`, `wochenraster-quer-hell`, `wochenraster-quer-hell-xxxl`, `ueberlappung-detail-hell` (Antippen eines überlappenden Termins), `ziehen-nachher-hell` (Block nach echtem Ziehen verschoben).
- Mac (Offscreen-Rendering, kein Fenster): `mac-wochenraster-hell|dunkel`, `mac-rollback-hinweis-hell`.
- Echtes Backend (iPad, `CalendarLiveTour`, Konto aus `testLiveSeedCalendarTourAccount`): `live-ipad-vorher-ziehen`, `live-ipad-nach-ziehen-neustart` (Termin B per Ziehen von 10:30 nach 13:45, nach Neustart unverändert).
iPad quer: Der Simulator liefert die Bildschirmaufnahme im gedrehten Format; die Tour schreibt `...-roh.png`, danach `sips -r 270`. Mac: `TODO_DEBUG_CALENDAR_RENDER=<Ordner>`. Live-Lauf: `TODO_UITEST_SERVER`, `TODO_UITEST_TOKEN`, `TODO_TOUR_OUT`; auf dem iPad löst ein langer Druck (>= 1 s) das Kontextmenü statt des Ziehens aus, die Tour drückt 0,5 s.

## Noch offen
Dauer per Ziehen am unteren Rand, Monatsansicht, Tastatur (Pfeile verschieben, Umschalt+Pfeil Dauer), Rückgängig, Mac im echten Fenster, dunkle Fassungen der neuen Blätter (Detail, Editor, Überlappung), Auto-Start-Nachholen-Rückfrage (ADR 0033 Abschnitt 4), App-Ende-zu-Ende mit Offline (nur auf Client-Ebene belegt, siehe STATUS).
