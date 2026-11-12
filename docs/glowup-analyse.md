# Glow-up Apple-App: Analyse PWA gegen iPhone-App

Stand 12.11.2026, Branch `glowup` (Basis `main` 3cef6d1). Todolino-Karte 1786DB8B („Apple-App Glow-up“).
Auslöser (Lino, 12.11.): „Auf dem iPhone nutze ich gerade lieber die PWA statt App.“ und „Die iOS-App ist zu unaufgeräumt und ich habe keine Ahnung, wo ich was finde. Das liegt vielleicht daran, dass sie von Todoist kopiert wurde.“

Methode: Code beider Clients gelesen (App: `App/Shared`, PWA: Hauptrepo `web/src/lib`), Simulator-Screenshots der App (iPhone 18 Pro, iOS 27.0, Debug, lokales Backend auf SQLite mit Demodaten aus `testSeedDemoData` plus Kriterien/Claim/Markdown-Review per REST). Aufgerufen per `TODO_DEBUG_SELECT` (kein echtes Tippen). PWA nicht im Browser angesehen, nur Code. Screenshots: `docs/screenshots/glowup/`.

## Kurzfassung: warum die PWA gewinnt

1. **Struktur ist Todoist, nicht Todolino.** Die iPhone-Tabs sind Für dich, Eingang, Heute, Anstehend, Durchsuchen (`MainView.swift` `PhoneTabs`, Z. 164–181): drei von fünf Tabs sind Datumslisten für private To-dos. Was Todolino ausmacht (Steuerzentrale, Projekte mit Board, Agenten/Runner) liegt im fünften Tab „Durchsuchen“, dort erst unter vier doppelten Einträgen (Bild `iphone-before-browse.png`: Für dich, Suche, Eingang, Heute, Anstehend, Steuerzentrale, Filter; Projekte erst nach Scrollen).
2. **Das Kartendetail kennt keine Agenten.** Wer eine Karte öffnet, sah Fällig, Wiederholung, Erinnerung, Priorität, Labels (Todoist-Formular, `TaskDetailView.swift`), aber weder die offene Rückfrage noch das Review, den Fortschritt, die Kriterien, wer daran arbeitet oder die Build-Screenshots (Bild `iphone-before-task.png`: Karte mit offener blockierender Frage, 40 % Fortschritt und Build zeigt nichts davon). Die PWA öffnet jede Karte als großes Detail mit Frage/Review, Unterhaltung, Beschreibung als Markdown, Bildern, Kriterien, Unteraufgaben, Abhängigkeiten, Meilenstein, Bearbeiter (`card/CardDetailBody.svelte` Z. 298–460). **In Welle 1 behoben** (siehe unten).
3. **Agententexte erschienen roh.** Fragen, Reviews, Fortschritt und Kommentare wurden per `Text(verbatim:)` gezeigt (`CommandCenterParts.swift` Z. 316/378/519, `FeedView.swift`, `TaskDetailView.swift`): Agenten schreiben Markdown, also stand dort `**Ergebnis:**` und `` `todolino.de` `` (Bild `iphone-before-feed.png`, dritte Karte). Die PWA rendert Markdown (`Markdown.svelte`). **In Welle 1 behoben.**
4. **Keine Unterhaltung an Karten, Fragen und Reviews.** Die PWA hat je Karte einen Chat sowie eigene Verläufe je Frage und Review (`card/CardConversation.svelte`, `thread` = task/question/review); die App kennt nur flache Aufgabenkommentare (im App-Code 0 Treffer für `thread`). Rückfragen an den Agenten („warum?“, „mach X statt Y“) gehen in der App nicht.
5. **Funktionslücken gegenüber der PWA.** Nur in der PWA: Bestätigungen (Action Requests, z. B. Projekt übertragen, `overview/ConfirmationCard.svelte`), Kriterien bearbeiten, Abhängigkeiten, Meilensteine, Aufgaben-Graph, Projektmodus (Klassisch/Projektmanagement), „Als Nächstes“, Filter, Einstellungs-Hub (Passkeys, Sitzungen, Darstellung, Verbindungen/MCP, Runner koppeln, Daten). Die App hat dafür Offline-Sync, Push und Haptik, die die PWA nicht hat.

Tempo spricht eher für die App (lokaler SQLite-Stand, Sync-Queue, Long-Poll-Live-Refresh, `LiveHub.swift`); gemessen wurde nichts. Der Unterschied liegt bei Struktur und Inhalt, nicht bei Geschwindigkeit.

## Informationsarchitektur (Hauptbefund)

### Einstiege auf dem iPhone (App, vorher)

| Ort | Einträge |
|---|---|
| Tab-Leiste | Für dich, Eingang, Heute, Anstehend, Durchsuchen (5) |
| Durchsuchen, Kopf | Avatar-Menü (Konto, Teams, Abmelden), Glocke (nur Team-Einladungen) |
| Durchsuchen, oben | „Aufgabe hinzufügen“ (zusätzlich zum FAB) |
| Durchsuchen, Liste | Für dich, Suche, Eingang, Heute, Anstehend, Steuerzentrale, Filter und Etiketten, Mehr (Teams, Konto, Aktivität, Runner) |
| Durchsuchen, darunter | Favoriten, Meine Projekte (Baum), Teams, Hilfe-Fußzeile |
| Projektseite, Leiste | fünf Symbol-Knöpfe ohne Text: Kommentare, Steuerzentrale des Projekts, Teilen, Anzeige (Liste/Board), Mehr (Bild `iphone-before-board.png`) |
| Steuerzentrale | Benachrichtigungs-Karte, Zählerchips, Segmente Überblick/Updates/Fragen, Spalten/Liste-Schalter, Menü (Bild `iphone-before-cc.png`) |

Rund 20 Einträge in „Durchsuchen“. Doppelte Wege: Für dich, Eingang, Heute, Anstehend je zweimal (Tab und Liste); Teams viermal (Mehr, Avatar-Menü, Abschnitt Teams, Glocke); Konto zweimal; Aufgabe anlegen zweimal (FAB, Zeile). Fragen und Reviews stehen an drei Stellen (Für dich, Steuerzentrale-Überblick, Steuerzentrale „Fragen“), mit unterschiedlicher Darstellung.

### Was nach Todoist aussieht, aber nicht zu Todolino passt

- Tabs Eingang/Heute/Anstehend/Durchsuchen sind Todoists iPhone-Leiste; Todolinos Kern (Agenten steuern, Fragen beantworten, Reviews abnehmen, Board ansehen) hat keinen eigenen Tab.
- „Eingang“ ist hier kein Projekt, sondern „alles ohne Fälligkeit“ (`InboxView`): bei Agenten-Projekten sind das fast alle Karten (Zähler 8 im Demo), also ein Rauschen-Tab mit rotem Badge.
- Kartendetail als Todoist-Formular (Fällig, Wiederholung, Erinnerung, Priorität, Labels zuerst); Agentenstatus fehlte.
- Zeilen zeigen P1–P3 und Datum, aber nicht „Frage offen“/„Review“ (Projektliste `iphone-before-project.png`: „Design-Review vorbereiten“ mit offener blockierender Frage sieht aus wie jede andere Zeile).
- Begriffe: „Durchsuchen“, „Filter und Etiketten“, „Anstehend“ (Todoist), daneben „Steuerzentrale“, „Runner“ (Todolino). Die PWA sagt „Überblick“ statt „Steuerzentrale“ und „Agenten“ statt „Runner“.

### Und die PWA?

Auch die PWA ist auf dem Handy Todoist-nah: Tabs Für dich, Heute, Anstehend, Suche, Menü (`Workspace.svelte` Z. 402–411); die Steuerzentrale heißt „Überblick“ und steht im Menü (Seitenleiste, `Sidebar.svelte` Z. 233–251). Sie gewinnt nicht durch eine bessere Gliederung, sondern weil (a) „Eingang“ nicht in der Leiste steht, (b) jede Karte überall als großes Detail mit Agentenkontext und Chat aufgeht (`CardDetailDialog`), (c) Markdown gerendert wird und (d) neue Funktionen zuerst dort landen. Die PWA-Gliederung 1:1 zu übernehmen löst Linos „ich finde nichts“ deshalb nur zum Teil; empfohlen wird eine eigene, kleinere Struktur (Variante A unten).

## Abläufe (Taps auf dem iPhone, ab Start)

| Aufgabe | App vorher | PWA | Bemerkung |
|---|---|---|---|
| Rückfrage beantworten | 1 (Für dich ist Start, Option tippen) | 1 | gleich |
| Review annehmen | 1 | 1 | Inhalt in der App roh (Markdown), jetzt behoben |
| Review mit Begründung zurückgeben | 2 + Text | 2 + Text | gleich |
| Karte mit Agentenstatus ansehen | nicht möglich (Detail ohne Agent) | 1–2 | jetzt in der App: Karte öffnen |
| Mit dem Agenten an einer Frage/Review schreiben | nicht möglich | 2 | Welle 2 |
| Steuerzentrale öffnen | 2 (Durchsuchen, Steuerzentrale) | 2 (Menü, Überblick) | gleich, aber in der App unter Doppel-Einträgen |
| Board eines Projekts öffnen | 3–4 (Durchsuchen, scrollen, Projekt, ggf. Board-Schalter) | 2–3 | |
| Schnell erfassen vom Start aus | 2 (Tab wechseln, FAB) – Für dich hatte keinen FAB | 1 (FAB global) | jetzt 1 in der App |

## Optik

Einzeln betrachtet sauber (Tokens, Karten, Dynamic Type seit dem UI-Audit, `docs/UI-AUDIT.md`). Unruhe entsteht durch Menge: Steuerzentrale stapelt fünf Bedienebenen über dem Inhalt; Projektseite fünf unbeschriftete Symbole; Farbwechsel zwischen Rot (Annehmen im Feed), Grün (Annehmen in der Steuerzentrale) und System-Blau (Knöpfe im Detail-Sheet, das den Marken-Tint nicht erbte – jetzt behoben). Offene Punkte aus F129D2F7: macOS-Fenster nie gesehen, `#Preview` nur teilweise, Zählerchips ohne Scroll-Hinweis, Projektpalette/`tile*`-Farben nicht als Assets, iPad-Detail bei AX lang.

## Welle 1 (umgesetzt auf `glowup`, ohne Designentscheidung)

- **Agent-Abschnitt im Kartendetail** (`AgentContextCard.swift`, `TaskDetailView.swift`): oben im Detail, nur wenn es Agentenarbeit gibt: Bearbeiter, Fortschritt mit letzter Notiz, offene Fragen (beantwortbar), offenes Review (annehmen/zurückgeben), Kriterien, Build-Screenshots. Daten aus `GET /v1/tasks/{id}/context`, das das Detail ohnehin lud (bisher nur für Unteraufgaben); Live-Refresh aktualisiert mit. Vorher/nachher: `iphone-before-task.png` → `iphone-after-task.png`, `iphone-after-review.png`.
- **Markdown** (`MarkdownFormat`/`MarkdownText`): Fragen, Reviews, Fortschritt, Updates, Feed-Karten, Kommentare (Aufgabe und Projekt), Runner-Ergebnisse. Inline-Markdown (fett, kursiv, Code, Links), Zeilenumbrüche bleiben, `#`-Überschriften werden fett; Listen bleiben als „- “-Zeilen. Vorher/nachher: `iphone-before-feed.png` → `iphone-after-feed.png`.
- **FAB auf „Für dich“**: Der Start-Tab war der einzige Haupt-Tab ohne Schnellerfassung (`FeedView.swift` `.quickAdd()`); jetzt wie in der PWA.
- **Marken-Tint im Detail-Sheet**: Bordered-Knöpfe im Detail waren System-Blau (Sheets erben den Tint nicht).
- **DEBUG**: `TODO_DEBUG_SELECT=browse` öffnet die Wurzel von „Durchsuchen“ (Screenshots).

Geprüft: Build Todo-iOS und Todo-macOS (`CODE_SIGNING_ALLOWED=NO`) grün; UI-Tests `Todo-iOS-UITests/TodoUITests` auf iPhone 18 Pro gegen das lokale Backend: 7 Tests, 6 bestanden, 1 übersprungen (iPad), 0 Fehler (inkl. Accessibility-Audits Detail und Für dich). Sichtprüfung nur iPhone hell/Standardgröße; Dunkel, AX, iPad und Mac nicht angesehen. Antworten/Entscheiden aus dem Detail nicht per Tippen geprüft (simctl kann nicht tippen); die Aufrufe sind dieselben wie in der Steuerzentrale (`answerQuestion`, `decideReview`).

## Plan (Wellen, Karten unter 1786DB8B)

- **Welle 1 – Agenten im Detail, Markdown, Schnellerfassung** (erledigt bis auf Review).
- **Welle 2 – Navigation neu (nach Linos Entscheidung)**: Variante A/B/C (Skizze `navigation-varianten.png`), danach Durchsuchen ohne Doppel-Einträge, Projektseite mit beschrifteten Aktionen, Agentenstatus in Zeilen und Board-Karten.
- **Welle 2 – Unterhaltung an Karten** (Apple-Teil von 84F150E5): Chat je Karte, je Frage und je Review.
- **Welle 3 – Funktionslücken**: Bestätigungen (Action Requests), Kriterien bearbeiten, Projektmodus (2EC67248), Abhängigkeiten/Meilensteine lesen, Einstellungs-Hub (Darstellung, Passkeys, Sitzungen, Verbindungen, Runner).
- **Welle 4 – Politur und Plattformen**: Steuerzentrale entschlacken, Farben vereinheitlichen, Folgepunkte F129D2F7 (macOS-Fenster, `#Preview` je Screen, Zählerchips, Tab-Leisten-Ränder, iPad-Detail bei AX, Projektpalette/`tile*` als Assets).

## Offene Entscheidungen (an Lino)

Navigation (Variante A „Agenten zuerst“ mit 4 Tabs Für dich/Projekte/Planen/Suche, B „wie die PWA“, C „minimal“). Bezug: Karte 2711B608 („UI Rework durch Codex, erst Konzept mit Figcraft“) – falls Lino dort zuerst ein Figma-Konzept will, wäre Welle 2 Navigation dessen Gegenstand.
