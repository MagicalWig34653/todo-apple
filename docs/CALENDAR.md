# Kalender (Apple) – Regeln, Endpunkte, Schreibweg

Karte 8CECAD24. Vorlage: ADR 0033 (Hauptrepo `docs/adr/0033-kalender-geplanter-start-und-waechter.md`, Abschnitt 3), PWA `web/src/lib/calendar.ts`. Verträge: `contracts/planning-ext.yaml` 1.2.0, `contracts/sync.yaml` 1.5.0. Stand: Phase 1 (Client-Bausteine in TodoCore, statische Vorschau in der App). Ziehen, Schreiben und Offline sind Phase 2.

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

## Online-PATCH oder Sync-Queue (Entscheidung)
- Online immer `PATCH .../schedule`: Teilschreibweg mit Version und genauen Fehlern; sync 1.5.0 sagt ausdrücklich, das Verschieben läuft online darüber.
- Offline ist `task.planning` (Queue, Vollersatz) nur der Rückfall (`ScheduleWriteRoute.choose`). **Lücke:** `SyncMutation` kennt `plannedMinutes`/`plannedAllDay` noch nicht, und die lokale Anzeige der Queue (`planningData`) trägt sie nicht. Verschieben/Entplanen (nur `plannedAt`) ist deshalb queue-fähig, Ganztägig und Dauer nicht (`unavailableOffline`: mit Hinweis ablehnen, nichts geht verloren). Die Mutation um die Schlüssel zu erweitern (nur senden, wenn gesetzt, "nur übernommen wenn gesendet") und Overlay/Store anzupassen ist Phase 2; dort auch entscheiden, ob Offline-Drops einen Versionskonflikt-Dialog brauchen.
- Die REST-Outbox (`PlanningOutbox`) ist die Brücke für Server vor 1.4.0 und bleibt unverändert; sie replayt `PUT` mit dem mitgeführten `PlanningData`.

## UI (Phase 1: nur Ansicht, Beispieldaten in Vorschauen)
- Einstieg: Seitenleiste "Planen" (iPad/Mac), Cmd-8, iPhone: Schaltfläche "Kalender" in der Werkzeugleiste von "Planen" (Tab-Struktur und Heute/Anstehend/Eingang unverändert).
- iPhone und alle Layouts ab Accessibility-Textgröße: Kopf mit Wochenzeile, Datum, Wochenstreifen, Tageskarten mit Uhrzeit/Dauer/Marken, "Ohne Termin" als Blatt. iPad/Mac: Wochenraster (15-Minuten-Linien, Ganztägig-Zeile, Fristmarken, Jetzt-Linie) mit Seitenleiste; zu schmal: Blatt statt Leiste, noch schmaler: Tagesliste (`ViewThatFits`).
- Marken immer mit Symbol und Text (Frist, Konflikte, Auto-Start nur als Anzeige, erledigt, nur lesen).
- Debug: `TODO_DEBUG_CALENDAR_PREVIEW=1` (Beispieldaten, kein Server), `TODO_DEBUG_SELECT=calendar`. Aufnahmen: `App/UITests/CalendarPreviewTour.swift` nach `docs/screenshots/kalender-apple-vorschau/`.

## Phase 2 braucht
Ziehen (`draggable`/`dropDestination`, Bearbeiten-Blatt "Start und Dauer" für iPhone), Schreiben über `CalendarDrop` und `ScheduleWriteRoute` mit Rollback/Neuladen, Rolle der Seitenleistenkarten (`canEdit` kommt dort nicht vom Server), Live-Refresh, Queue-Erweiterung (oben), Dauer per Ziehen am unteren Rand, Monatsansicht, Tastatur/VoiceOver-Aktionen, Ende-zu-Ende gegen das native Backend.
