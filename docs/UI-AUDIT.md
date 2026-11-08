# UI-Audit Todolino (Layout und Optik)

Stand 07.11.2026, Basis `f84f055`. Nur Audit, kein Produktcode geändert. Methode: statische Prüfung von `App/Shared` (grep und Lesen) gegen die Checkliste, dazu Simulator-Screenshots (Todo-iOS, Debug, `CODE_SIGNING_ALLOWED=NO`): iPhone 18 Pro und iPad 13, hell/dunkel, Dynamic Type Standard (`medium`) und `accessibility-extra-large`. Backend: lokales `.build/debug/App` (SQLite, Port 28777) mit Demodaten aus `testSeedDemoData` (Seed State/Feed/Board). Screenshots (auf 900 px Kantenlänge verkleinert) liegen in `docs/screenshots/audit/`, Namensschema `<gerät>-<ansicht>-<hell|dunkel>-<medium|accessibility-extra-large>.png`.

Schweregrad: B = Blocker (Inhalt unbenutzbar/abgeschnitten), H = hoch (sichtbarer Layoutfehler), M = mittel (Inkonsistenz/Robustheit), N = niedrig (Hygiene).

## Ausgangslage

- Es gibt **keinen** Seitenrand-Token. `Space` kennt xxs 2 bis xxl 32, Seitenrand wird je Datei ad hoc gesetzt: 16 (Listen, Sidebar), 20 (Projektkopf, Login), 12 (Wochenstreifen), 14 (Karten). Sichtbar: Projekttitel (x=47 px) steht gegenüber den Listenzeilen darunter (x=37 px) eingerückt (`iphone-board-light-medium.png`, `iphone-project-umzug-light-medium.png`).
- `Space` wird kaum genutzt: 123 Stellen mit `spacing: <Zahl>` und 77 mit `.padding(<Zahl>)` außerhalb von Theme; Werte außerhalb der Skala (3, 5, 6, 7, 9, 10, 11, 14, 18, 20, 28).
- Keine einzige `#Preview` im Projekt.
- Keine maximale Lesebreite außer Feed (720) und Login (460/520). Auf iPad/Mac laufen Listen, Projektkopf, Konto und Steuerzentrale über die volle Detailbreite (`ipad-today-light-medium.png`: Zeile ca. 1000 pt breit, Projektname steht am rechten Rand weit vom Titel entfernt).
- Positiv: Fonts durchgängig semantisch, Farben aus Assets, 44-pt-Ziele über `tapTarget()`, Mac-Mindestgröße gesetzt.

## Befunde nach Datei

### TaskComponents.swift
- **H** Z. 229-232 (`TaskRow`): Checkbox mit `.padding(.leading, -10).padding(.top, -6)` kompensiert die 44-pt-Trefferfläche mit Magic Numbers. Bei AX-Größen ragt der Kreis über den linken Rand hinaus und wird am Bildschirmrand angeschnitten (`iphone-today-light-accessibility-extra-large.png`, Kreis bei x=14 px statt 37 px). Fix: Trefferfläche über `contentShape`/`tapTarget()` ohne negatives Padding, Spalte der Checkbox über ein gemeinsames Layout (Grid oder fester Leading-Inset aus Token).
- **M** Z. 199 (`TaskCheckbox`) skaliert per `@ScaledMetric` ohne Obergrenze: bei AX wird der Kreis über 60 pt groß und dominiert die Zeile; ab `isAccessibilitySize` auf z. B. 36 pt deckeln.
- **M** Z. 425 und 437: FAB-Abstand `fabSize + 28`, `.padding(.trailing, 20).padding(.bottom, 14)`: freie Zahlen; bei AX überdeckt der FAB Zeilentext (`...today-light-accessibility-extra-large.png`, "dringend"/"Eingang"). Fix: FAB als `safeAreaInset(edge: .bottom)`-Overlay mit Token-Rand, bei AX auf kompakte Größe.
- **N** Z. 322, 408: `.padding(.top, 3)`, `.padding(.vertical, 2)`. Z. 341: `.secondary` statt `textSecondary`. Z. 195, 430, 433: `.white` (auf Marken-Fläche vertretbar, besser Token `onBrand`).
- **N** Metazeile rechts ausgerichtetes Projektlabel (`Spacer`) wandert auf iPad an den rechten Rand, Blickweg zu lang: Projekt direkt hinter die Meta setzen oder Lesebreite begrenzen.

### MainView.swift / Sidebar.swift
- **H** MainView Z. 122-139 und Sidebar Z. 259: Beim Wechsel auf "Mehr"-Ziele (Projekt, Konto, Steuerzentrale, Teams) erscheinen auf dem iPhone **zwei übereinander liegende Zurück-Schaltflächen** (`iphone-account-light-medium.png`, `iphone-project-umzug-light-medium.png`, `iphone-cc-light-medium.png`, `iphone-board-light-medium.png`). Ursache wahrscheinlich: `browsePath = [item]` in `syncFromSelection` (Z. 196) plus eigene Navigation/`model.selection` setzt ohne Root-Wechsel; eventuell Debug-Link-Artefakt (Start per `TODO_DEBUG_SELECT`), per manuellem Tippen **nicht verifiziert**. Fix: Pfad nur beim Antippen setzen, nach Deep Link prüfen, ob die Leiste dupliziert wird; nur eine NavigationStack-Ebene je Tab.
- **M** Sidebar Z. 63-66: `.padding(.leading, 12)` je Zeile von Hand, Z. 127, 224 `.padding(.horizontal, 16).padding(.vertical, 10)`, Z. 220 `.padding(16).frame(minWidth: 240)`. In `ipad-today-light-medium.png` haben Projektzeilen (Hash-Symbol) und Tile-Zeilen verschiedene Einrückungen und Zeilenhöhen (Eingang bis Website-Relaunch deutlich höher als Tile-Zeilen). Fix: gemeinsame `SidebarRow`-Metrik (Höhe, Leading, Icon-Spalte) mit Token.
- **M** Sidebar Z. 193-194: Avatar 28x28 fest ohne `ScaledMetric`.
- **N** Sidebar Z. 392 und LoginView Z. 233: `minHeight: 28` (Mac-Ziel), auf iOS 44 durch `tapTarget` ersetzen, falls berührbar.
- **N** Sidebar Z. 56, 412, 415: `.tertiary` für Chevron, harmlos (nur Zier), Z. 412 `.white` auf Auswahl.
- **N** MainView Z. 68: `idealWidth: 560` für Sheet, aber keine Höhe ideal (nur minHeight 600).

### ProjectPage.swift
- **H** Z. 90: Kopf `padding(.horizontal, 20)` gegenüber Listenzeilen 16 (siehe Ausgangslage, sichtbar versetzter Titel und Beschreibung). Fix: Seitenrand-Token.
- **M** Z. 105-125: Werkzeugleiste mit fünf Icon-Buttons, auf iPad Projektseite im Inspector-Fall doppelt (siehe TaskDetailView). Auf iPhone ist die Toolbar mit zwei Zurück-Schaltflächen (MainView) überladen; Breadcrumb auf iPhone/principal verdrängt.
- **M** Z. 160 `spacing: 14`, Z. 180 `.padding(16).frame(minWidth: 300)` (Popover) ohne Obergrenze.
- **M** Z. 76-95: Kein `maxWidth` für Titel/Beschreibung auf iPad/Mac.

### AgendaView.swift
- **M** Z. 156: `.padding(.horizontal, 12)` am Wochenstreifen, andere Seitenränder 16; Z. 141 `spacing: 4`, Z. 137 `spacing: 6`; Z. 148 feste `min(cellWidth, 70)` mit `GeometryReader`-artiger Zellrechnung (bei AX nur Skalierung der Zelle).
- **M** Z. 60: `.padding(.top, 120)` für Skeleton, Magic Number, überdeckt bei kleinen Geräten Inhalt.
- **N** Z. 143-146: `Color.white` auf Auswahlzelle (Brand-Fläche), Token `onBrand`.
- **M** Z. 63-64: Inline-Titel "Heute" **und** großer Titel "Heute" sichtbar doppelt (`iphone-today-light-medium.png`, oben "Heute" in der Leiste, darunter großer Titel). Fix: `navigationTitle` leer oder großen Titel entfernen, nicht beides.
- **M** AX: Meta-Zeilen der Aufgabe brechen in eine Spalte je Element (siehe `...today-light-accessibility-extra-large.png`), Zeilenhöhe > 600 pt, "Auf heute legen"-Kapsel rutscht unter die Überschrift; akzeptabel, aber Abstand zwischen Titel und Meta unregelmäßig.

### BoardView.swift / CommandCenterView.swift / CommandCenterParts.swift
- **H** CommandCenterView Z. 459 und iPad-Toolbar: Segmentierter Modus-Schalter (Spalten/Liste) dehnt sich über ca. 700 pt, Titel wird zu "Steuerzent..." abgeschnitten (`ipad-cc-light-medium.png`). Fix: `Picker` mit `.fixedSize()`/`frame(maxWidth: 160)` in der Toolbar, Titel `.principal` mit `lineLimit(1)` + Mindestbreite.
- **H** CommandCenterParts Z. 217-221: Screenshot-Thumbnail fest 84x112, in der Karte als einfarbig lachsroter Block ohne Beschriftung/Inhalt dargestellt (`ipad-cc-light-medium.png`, Karte "Frage offen"); Platzhalter-Farbe wirkt wie Fehler. Fix: neutrale `hairline`-Fläche, `containerRelativeFrame` für Kartenbreite, Seitenverhältnis statt fester Höhe.
- **M** BoardView Z. 28 und CommandCenterView Z. 201: `GeometryReader` für Spaltenbreite; mit `containerRelativeFrame(.horizontal) { w, _ in ... }` im horizontalen ScrollView ersetzbar (sauberer, kein Layout-Pass-Sprung). Z. 64 `frame(width: baseWidth * 0.95)`, Z. 137 `frame(width: width)`.
- **M** BoardView Z. 262 und TaskComponents Z. 231: `.padding(.leading, -10).padding(.top, -6)` (siehe oben).
- **M** CommandCenterView Z. 426-443, CommandCenterParts Z. 244: `.padding(8)`, `.padding(14)`, `.padding(16)`, `.padding()` gemischt innerhalb derselben Ansicht.
- **M** CommandCenterView: Benachrichtigungs-Primer-Karte steht oberhalb des Titels und verschiebt Titel/Chips (`iphone-cc-light-medium.png`, `ipad-cc-light-medium.png`); Primer nur einmal in Konto/Für dich zeigen oder unter den Zählerchips.
- **M** Zählerchips Z. 101-103 laufen auf iPhone/iPad als horizontale Leiste mit abgeschnittenem letzten Chip ("Kürzlich erledigt" angeschnitten); gewollt (Scroll), aber ohne Rand-Fade/Scroll-Hinweis; `FlowLayout`/`ViewThatFits` prüfen.
- **N** CommandCenterParts Z. 218-219: `cornerRadius: 8` statt `Radius.s`; Z. 433 `cornerRadius: 2`; BoardView Z. 369-373 `cornerRadius: 4`; Z. 448 `.padding(.horizontal, 6)`.
- **N** CommandCenterParts Z. 185: `.tertiary` Symbol; Z. 229 `.padding(.horizontal, 4)`.
- **M** Z. 330 (CommandCenterView) `frame(width: 22)`, Z. 201 (FeedView) `frame(width: 24)`, LoginView Z. 127, ServerViews Z. 141 `frame(width: 22)`: feste Symbolspalten ohne `ScaledMetric` (bei AX schneidet das Symbol aus der Spalte).

### TaskDetailView.swift
- **H** Z. 260 (`.padding(.leading, -8).padding(.top, -2)`): Titelzeile mit Checkbox; bei AX steht der übergroße Kreis eigenständig über dem Titel am linken Rand, angeschnitten (`iphone-task-dark-accessibility-extra-large.png`). Fix wie TaskRow.
- **H** iPad-Inspector: Obere Leiste zeigt gleichzeitig "Fertig", Projekt-Menü und die Projekt-Toolbar (Kommentare, Board, Teilen, Anzeige, Mehr) des dahinterliegenden Projekts (`ipad-task-light-medium.png`); der Inspector sollte nur seine eigene Aktionsleiste haben (`.toolbar` der Detailseite von der Hostansicht trennen, "Fertig" nur im Sheet).
- **M** Z. 561 `Circle(...).frame(width: 7, height: 7).padding(.top, 6)`, Z. 410 `9x9`, Z. 505 `28x28` Avatar, Z. 476 `frame(width: 24)`: feste Maße ohne ScaledMetric.
- **M** Z. 299 `Divider().padding(.leading, 40)`, Z. 311/316 `minHeight: 44` vs `46`, Z. 553 `44`: uneinheitliche Zeilenhöhen (44/46), Z. 390 `.padding(.horizontal, 9).padding(.vertical, 4)`.
- **M** Eigenschaftenkarte: AX stapelt Label und Wert vertikal, ein Zeilenblock mit Icon, Label, Wert benötigt ca. 290 pt je Zeile; nur 3 Zeilen sichtbar pro Bildschirm (`...task-dark-accessibility-extra-large.png`). Fix: Icon-Kachel bei AX kleiner, Wert in Zeile des Labels belassen (Wert `lineLimit(2)`).
- **M** Z. 268: `.tertiary` Symbol; Z. 535 `.secondary.opacity(0.5)` für deaktivierten Senden-Button (Kontrast gering, `iphone-task-light-medium.png`: Pfeil kaum erkennbar).
- **M** Kommentarleiste: bei AX Platzhalter "Kommentar sc..." abgeschnitten, Eingabe einzeilig; `axis: .vertical` und `lineLimit(1...4)`.
- **N** Keine Lesebreite für Inspector-Inhalt, auf Mac/iPad im Sheet (`MainView` Z. 65-68) ok.

### QuickAddSheet.swift
- **B** Z. 44 und `ipad-quickadd-*.png`: Auf iPad erscheint das Blatt als schmales Panel (ca. 380 pt) am unteren Rand mit nur ~100 pt sichtbarer Höhe; Priorität-/Label-Zeile und Senden-Button sind abgeschnitten (`ipad-quickadd-light-medium.png`). `presentationDetents([.medium, .large])` ohne `presentationSizing`. Fix: iPad/Mac `presentationSizing(.form)`, `.large` Detent bevorzugen, oder `frame(idealHeight:)`.
- **M** Z. 171 `.padding(.horizontal, 11).padding(.vertical, 7)` (Chip, beide Werte außerhalb der Skala), Z. 164 `spacing: 5`, Z. 63/93 `spacing: 10`, Z. 113 `.padding(16)`, Z. 138 `.padding()`.
- **M** Z. 48 Mac `frame(width: 440, height: 380)` fest, keine Größenanpassung bei Dynamic Type.
- **N** Z. 100 `.white`, Z. 101 `frame(width: sendSize...)` (ScaledMetric vorhanden, gut).

### LoginView.swift
- **H** Z. 51-59: Spalte hat `maxWidth: 460` und `padding(.horizontal, 20)`; gut, aber Anmeldekarte (Z. 118-122) zeigt Hintergrund `Color.canvasRaised` über dem inneren Server-Feld mit anderem Radius (24/14/12/16, Z. 119, 137, 221, 236, 251): vier Radien in einem Screen, keiner aus `Radius`. Server-Fehlerbox und deaktivierter Hauptbutton (Mauve, `iphone-login-light-medium.png`) und die Nebenlinks "Mit Wiederherstellungscode anmelden / Konto erstellen" sind sehr blass (Kontrast < 3:1, wirkt deaktiviert).
- **M** Z. 14-28: Logo mit mehreren festen `frame(width:)`/`offset` plus `font(.system(size: card * 0.46))` (Z. 22), nicht skalierend (nur Logo, vertretbar, aber ohne `ScaledMetric`).
- **M** Z. 269: `frame(maxWidth: 520).padding(20)`; Z. 282 Mac `minWidth: 440, minHeight: 420`.
- **M** Spacing 28/18/14/10 (Z. 51, 268, 89, 109 ...) und Paddings 20/32/24/12/14 ohne Token.
- **N** Z. 23, 232, 310, 373, 424, 473: `.white`/`.tint(.white)`, Z. 121 `.black.opacity(0.05)` Schatten. Z. 188 `.secondary`.
- **N** Z. 134 `.tertiary` Chevron.

### FeedView.swift
- **M** Z. 26 `maxWidth: 720` ist die einzige Lesebreite im Projekt; Karten-Innenrand uneinheitlich: Aktionsbuttons beginnen links bei x=64 px, Titel bei x=130 px, Icon bei x=68 px (`iphone-feed-light-medium.png`). Fix: gemeinsame Content-Spalte, Buttons auf Titelkante oder Kartenrand.
- **M** Aktionsbuttons (Ja/Nein, Annehmen, Erledigt): fast gleichfarbige Kapseln (Brand 12 % Hintergrund und Brand-Text), sehen deaktiviert aus (`iphone-feed-light-medium.png`, `...-dark-medium.png`); eine Aktion je Karte primär (`borderedProminent`).
- **M** Z. 221 Bild fest `220x300`/`150x200` statt Seitenverhältnis. Z. 42 Mac `minWidth: 420, minHeight: 520`.
- **N** Z. 34 `.padding()`; Z. 114/202 `spacing: 2`.

### AttachmentsView.swift / ServerViews.swift / TeamsView.swift / NotificationSettings.swift / SearchView.swift / Theme.swift
- **M** ServerViews Z. 94 `.padding(12).background(.bar)`, Z. 104 Mac-Sheet `minWidth: 460`; Z. 52 Avatar 28x28 fest; Z. 261-274 `.padding(.vertical, 2)`, `.padding(.horizontal, 8).padding(.vertical, 2)`.
- **M** NotificationSettings Z. 115-118: Karte mit `.padding(14)` (außerhalb Skala) + `.padding(.horizontal, 16).padding(.top, 8)` in einer Form/Liste ergibt Doppelpolster (`iphone-account-light-medium.png`: Primerkarte sitzt zwischen Gruppen mit anderem Außenrand); Z. 34-37, 111-112 `minHeight: 44` bei Mac unnötig.
- **M** TeamsView Z. 157 Mac-Sheet `minWidth: 420`; AttachmentsView Z. 166 `frame(width: 44, height: 44)` feste Größe statt `tapTarget`.
- **M** SearchView Z. 17, 38: Zeilen mit `spacing: 10`, `contentShape`-Rows statt Buttons (kein Pressed-Feedback), Z. 17 sehr lange Einzeiler.
- **M** Theme.swift Z. 272 `CountBadge .padding(.horizontal, 7).padding(.vertical, 1)`, Z. 296 `LabelChip .padding(.horizontal, 7).padding(.vertical, 2)`, Z. 249 `AdaptiveStack spacing: 8`, Z. 337 Skeleton `spacing: 7`, Z. 351-354 feste Breiten (Skeleton ok); Z. 361 `NoticeBanner .padding(.vertical, Space.s + 2)`: Basisbausteine setzen selbst Off-Scale-Werte, die in alle Ansichten wandern. Sollte zuerst bereinigt werden.
- **M** Theme.swift Z. 38-45: Projektpalette und Z. 177-182 `tile*`-Farben als `Color(red:green:blue:)` statt Asset (dark/high contrast fehlen, Kontrast zu `.white` Glyph laut HIG-Audit 3,0:1).
- **N** Theme.swift Z. 225 `IconTile`: `font(.system(size:))` skaliert über `ScaledMetric`, ok. Z. 232 `tapTarget()` nur iOS (Mac nicht, laut Konzept ~28 pt, aber `minHeight: 28` fehlt dort).

### TodoApp.swift
- **M** Z. 16, 21: Hauptfenster `minWidth: 820, minHeight: 560`, `defaultSize 1280x820` gut. Z. 101 Einstellungen `frame(width: 460, height: 560)` fest, nicht skalierend mit Dynamic Type/Text; Sheets (Sidebar Z. 253, CommandCenterView Z. 459, FeedView Z. 42) nur `minWidth/minHeight`, keine `idealWidth/idealHeight`.

### Querschnitt (alle Dateien)
- **M** Kein Seitenrand-Token (`Space.page`), keine zentrale Lesebreite (`ReadableWidth`-Modifier, z. B. `frame(maxWidth: 680)` + `frame(maxWidth: .infinity)` ab `horizontalSizeClass == .regular`).
- **M** `.listRowInsets(EdgeInsets(... leading: 16 ...))` (AgendaView Z. 14 und weitere) gegenüber ScrollView/VStack-Seiten mit `.padding(.horizontal, Space.l)`: beide Schemata gleichzeitig (Listenseiten vs. Karten-Seiten), erzeugen die 10 px Versatz zwischen Titel und Liste.
- **M** Dynamic Type: viele HStack mit `Spacer()` (MetaItem-Zeilen, Sidebar-Zeilen) ohne `ViewThatFits`; nur `AdaptiveStack` an ausgewählten Stellen.
- **N** `GeometryReader` nur 2x (Board, Steuerzentrale), siehe oben; keine `containerRelativeFrame`-Nutzung.
- **N** Keine `#Preview`; Empfehlung: je Datei Preview mit Beispieldaten (Standard, Dark, AX3), zuerst `TaskRow`, `TaskDetailView`, `QuickAddSheet`, Board-Karte, Feed-Karte, Login.

## Visuelle Funde (Screenshots)

| Ansicht | Beobachtung | Datei |
|---|---|---|
| Anmeldung | Hauptbutton blass/ausgegraut wirkend (Server nicht erreichbar, Standard-Port 28080 ist hier nur Artefakt), Nebenlinks sehr hell, Karte in Karte | `iphone-login-light-medium.png`, `iphone-login-dark-medium.png` |
| Heute | Doppelter Titel (Leiste und groß); Meta rechts Projektname; FAB überlappt letzte Zeile bei AX | `iphone-today-light-medium.png`, `iphone-today-light-accessibility-extra-large.png` |
| Heute iPad | Zeile über 1000 pt breit, keine Lesebreite | `ipad-today-light-medium.png` |
| Projekt/Liste | Titel 10 px eingerückt gegenüber Liste; doppelte Zurück-Schaltfläche (iPhone) | `iphone-project-umzug-light-medium.png`, `ipad-project-umzug-light-medium.png` |
| Board | Zwei Zurück-Schaltflächen, Tab-Leiste und FAB überdecken die letzten Zeilen (nur `contentMargins` auf Listen, nicht hier), Liste statt Board (Standardmodus) | `iphone-board-light-medium.png`, `ipad-board-light-medium.png` |
| Aufgabendetail | Checkbox/Titel bei AX angeschnitten; Eigenschaftenkarte bei AX stark gestreckt; Inspector auf iPad mit doppelter Toolbar | `iphone-task-dark-accessibility-extra-large.png`, `ipad-task-light-medium.png` |
| Steuerzentrale | Primer-Karte über dem Titel; iPad-Toolbar mit überbreitem Schalter, Titel abgeschnitten; rotes Thumbnail ohne Inhalt | `iphone-cc-light-medium.png`, `ipad-cc-light-medium.png` |
| Für dich | Aktionskapseln wirken deaktiviert (Brand auf Brand-Tönung), Innenränder uneinheitlich | `iphone-feed-light-medium.png`, `iphone-feed-dark-medium.png` |
| Einstellungen | Karte "Benachrichtigungen" mit zusätzlichem Rand zwischen Form-Gruppen; letzter Eintrag unter der Tab-Leiste abgeschnitten (Scroll-Inset fehlt) | `iphone-account-light-medium.png` |
| Schnellerfassung iPad | Blatt zu niedrig, Inhalt abgeschnitten (Blocker) | `ipad-quickadd-light-medium.png` |

Dunkelmodus: keine zusätzlichen Fehler gegenüber hell sichtbar außer wirkungsarmem Kontrast der Brand-Kapseln (`iphone-feed-dark-medium.png`). Das Material der schwebenden Tab-Leiste lässt Text darunter durchscheinen (`iphone-feed-light-medium.png`, unterer Rand: "Erledigt"/Titel hinter der Leiste lesbar), Folge der iOS-26-Leiste; Listen brauchen `contentMargins(.bottom, ...)` auch auf Feed, Konto, Board.

## Zählung

Blocker 1, Hoch 9, Mittel 49, Niedrig 17 (jeweils pro Zeile im Abschnitt "Befunde nach Datei"; Sammelbefunde "Querschnitt" und Tabelle nicht doppelt gezählt).

## Vorschlag Arbeitspakete

Voraussetzung (zuerst, klein, ein Mensch): **Paket 0 Tokens** in `Theme.swift`: `Space.page` (16), `Space` um 6 und 20 ergänzen (oder Werte auf Skala rastern), `ReadableWidth`-Modifier (`maxWidth` 680, zentriert, nur bei `regular`), `onBrand`-Farbe, `Radius`-Nutzung für Karten/Chips, Off-Scale-Werte in `CountBadge`, `LabelChip`, `NoticeBanner`, `AdaptiveStack` bereinigen, `ScaledMetric`-Hilfe für Symbolspalten, ggf. Asset-Farben für `tile*`/Projektpalette. Danach laufen die folgenden Pakete ohne Dateikonflikte parallel (jedes besitzt eigene Dateien).

1. **Paket A Listen und Heute** (`TaskComponents.swift`, `AgendaView.swift`, `SearchView.swift`): Checkbox ohne negatives Padding und mit Cap, FAB-Inset, doppelter Titel, Wochenstreifen-Rand, Lesebreite, Skeleton-Padding, Kontrast Senden-Button.
2. **Paket B Navigation und Seitenleiste** (`MainView.swift`, `Sidebar.swift`, `TodoApp.swift`): doppelte Zurück-Schaltfläche, einheitliche Sidebar-Zeilenmetrik, Sheet-Idealgrößen, Einstellungsfenster, `contentMargins` für Tab-Leiste in allen Tabs.
3. **Paket C Projekt und Board** (`ProjectPage.swift`, `BoardView.swift`, `BoardModel.swift` nur falls nötig): Seitenrand-Token, Kopf/Liste fluchten, `containerRelativeFrame` statt `GeometryReader`, Toolbar-Reduktion, Lesebreite für Titel, Radien.
4. **Paket D Steuerzentrale und Für dich** (`CommandCenterView.swift`, `CommandCenterParts.swift`, `FeedView.swift`, `FeedModel.swift`): Toolbar-Picker-Breite und Titel, Primer-Position, Thumbnail-Platzhalter und Seitenverhältnis, Aktionsbutton-Hierarchie, Kartenränder, Radien, Bildgrößen.
5. **Paket E Aufgabendetail und Schnellerfassung** (`TaskDetailView.swift`, `QuickAddSheet.swift`, `AttachmentsView.swift`): iPad-Quick-Add-Sheet-Größe (Blocker), Inspector-Toolbar, AX-Layout Eigenschaften, Checkbox-Kopf, Zeilenhöhen 44/46, Kommentarfeld mehrzeilig, feste Symbolspalten.
6. **Paket F Anmeldung, Konto, Server, Teams** (`LoginView.swift`, `NotificationSettings.swift`, `ServerViews.swift`, `TeamsView.swift`): Radien/Abstände/Seitenränder, Kontrast der Nebenlinks und des deaktivierten Buttons, Doppelpolster der Primerkarte, Mac-Sheet-Größen, `#Preview` je Screen.

`#Preview` je Datei kann jedem Paket als Abschlussschritt angehängt werden (alle Pakete besitzen ihre Dateien).

## Nicht prüfbar / Grenzen

- **macOS** nicht gebaut und nicht gestartet (nur Code gelesen): Fensterverhalten, Sheet-Idealgrößen, 28-pt-Ziele und Lesebreite am Mac sind ungeprüft.
- iPhone-Screens wurden per DEBUG-Deep-Link (`TODO_DEBUG_SELECT`) geöffnet, nicht per Tippen: die doppelte Zurück-Schaltfläche ist deshalb als Verdacht notiert, nicht bestätigt. Gestenverhalten (Swipe, Drag), Tastatur-Sheets und Animationen sind nicht beurteilt.
- Anmeldung nur im Zustand "Server nicht erreichbar" (App-Standardserver 127.0.0.1:28080 war nicht gestartet); Passkey-Fluss, Einrichtungs- und Wiederherstellungsseiten nicht sichtbar. Der Server lief nur für die übrigen Ansichten auf 28777.
- Board ist im Demo-Projekt "Vibecoding" im Listenmodus gestartet (Standardanzeige); die Kanban-Ansicht des Boards ist daher nicht in den Screenshots (frühere Screenshots `docs/screenshots/board2-*.png`).
- Dynamic Type nur `medium` und `accessibility-extra-large`; kleine Stufen, `xSmall` und Bold-Text, Reduzierte Transparenz und Hoher Kontrast nicht geprüft. iPad nur Hochformat. Keine Kontrastmessung, Aussagen zu Kontrast sind Sichtbefund.
- Debug-Build, Simulator-Statusleiste per `simctl status_bar` überschrieben (9:41).
- Zählungen der Magic Numbers (123/77) stammen aus `grep` und enthalten einige legitime Treffer (`ProjectDot`-Standardgröße, Skeleton-Werte, Wiederholungen in Previews/Debug).

## Nachher (Sichtprüfung 07.11.2026, Branch `ui-verify`, Basis `39a4d2f`)

Methode: Simulator-Klone (iPhone 17 Pro, iPad Pro 13"), Backend `.build/debug/App` auf SQLite, Port 28790, Demodaten mit State/Feed/Board, DEBUG-Hooks (`TODO_DEBUG_SELECT` usw.). Screenshots in `docs/screenshots/after/` (900 px). Alles per Deep Link geöffnet, nicht per Tippen. Alle Bilder wurden angesehen, die Dunkel-/AX-Wiederholungen nur als Stichprobe.

### Gesehen und gut (gegenüber Vorher)
- Schnellerfassung iPad (Blocker im Audit): Blatt jetzt formgroß mit Titel, Datum-Chips, Priorität/Labels, Senden und Projekt (`ipad-quickadd-light-medium.png`); bei AX scrollt das Blatt (`ipad-quickadd-light-accessibility-extra-large.png`).
- Lesebreite und Seitenränder iPad: Heute/Projekt in lesbarer Spalte, Titel fluchtet mit den Zeilen (`ipad-today-light-medium.png`, `ipad-project-umzug-light-medium.png`); iPhone-Projektkopf fluchtet (`iphone-project-umzug-light-medium.png`).
- Kanban-Spalten: Breite folgt dem Container, nächste Spalte angeschnitten als Scroll-Hinweis (`iphone-board-kanban-light-medium.png`, `ipad-board-kanban-light-medium.png`, dunkel ebenso).
- Checkbox: kein Anschnitt mehr, auch bei AX (`iphone-today-light-accessibility-extra-large.png`, `iphone-task-light-accessibility-extra-large.png`).
- Heute ohne doppelten Titel; Aufgabendetail iPhone/iPad ordentlich; Konto ohne Doppelpolster (`iphone-account-light-medium.png`); Anmeldung iPhone/iPad (`*-login-light-medium.png`); Steuerzentrale iPad: Titel nicht mehr abgeschnitten, Schalter kompakt.

### Behoben in dieser Runde
1. **Doppelte Zurück-Schaltfläche (H)**: Ursache war der sechste Tab (Suche). iOS packt ab dem sechsten Tab die überzähligen in sein eigenes "Mehr" (eigener Navigationscontroller); darin lag der Stack des Browse-Tabs, daher zwei Leisten. Suche liegt jetzt im Browse-Tab (`MainView.swift`, `PhoneTabs`), der Tab heißt wieder "Durchsuchen". Nachweis: `iphone-project-umzug-light-medium.png`, `iphone-account-light-medium.png`, `iphone-cc-light-medium.png` zeigen nur noch eine Zurück-Schaltfläche.
2. **iPad-Inspector mit Projekt-Toolbar (H)**: Projektaktionen entfallen, solange ein Detail im Inspector offen ist (`ProjectPage.swift`; `ipad-task-light-medium.png`).
3. **Steuerzentrale iPhone (M)**: doppelter Inline-Titel entfernt (`CommandCenterView.swift`).
4. **Review-Aktionen in schmaler Spalte (H)**: "Annehmen" wurde zum Kreis gestaucht; jetzt `ViewThatFits` nebeneinander oder untereinander (`CommandCenterParts.swift`).
5. **iPad-Sidebar bei AX (H)**: Einträge brachen mitten im Wort ("Ein-gan-g"); Spaltenbreite skaliert mit der Schrift, auf 400 pt begrenzt (`MainView.swift`; `ipad-today-light-accessibility-extra-large.png`).

### Offen
- **H** UI-Test `testAccessibilityAuditQuickAdd` schlägt fehl: "size of SwiftUI.VerticalTextView is too small for user to interact" (Element 370 x 54,7 pt bei y=156, vermutlich das Beschreibungsfeld). `tapTarget()` an Titel oder Beschreibung änderte nichts und wurde zurückgenommen. Ob der Befund schon vor den UI-Paketen bestand, wurde nicht geprüft.
- **H** Steuerzentrale: Screenshot-Thumbnail weiterhin einfarbig lachsrot (Demo-Bild ist 1x1 px, evtl. Testdatenartefakt; die Platzhalterfarbe wirkt dennoch wie ein Fehler) (`ipad-cc-light-medium.png`).
- **M** Steuerzentrale/Für dich: Antwort-Kapseln blass bzw. grau, wirken deaktiviert; Tab-Leiste überlagert beim Scrollen den Text (`iphone-feed-light-medium.png`).
- **M** iPad-Detail bei AX: Eigenschaftenkarte lang (Label/Wert gestapelt), Inspector eng (`ipad-task-light-accessibility-extra-large.png`).
- **M** Schnellerfassung AX: große Abstände zwischen Chips (`iphone-quickadd-light-accessibility-extra-large.png`).
- **N** Heute AX und Anstehend: FAB überdeckt die letzte sichtbare Zeile (`iphone-upcoming-light-medium.png`).

### Lücken
- macOS: Todo-macOS baut und startet, aber `TODO_DEBUG_SNAPSHOT` lieferte im Agentenlauf keine PNG und `screencapture` scheitert ohne Bildschirmaufnahme-Recht: Hauptfenster, Einstellungen und Sheet am Mac **nicht gesehen**.
- Zurück-Schaltfläche nicht per echtem Tippen geprüft (`simctl` kann nicht tippen), nur per Deep Link; kein Test dafür.
- Teams (Form) und Schnellerfassung iPhone (medium) nach den Korrekturen nicht (brauchbar) aufgenommen, daher nicht bewertet; iPad-Querformat nicht gemacht; Dunkel/AX nur Stichprobe; Sync-Statusleiste und Animationen nicht beurteilt.
- Tests: Todo-iOS-UITests auf iPhone-Klon, 7 Tests: 5 bestanden (Detail-Audit, Heute-Audit, Anlegen/Abschließen, Für-dich-Audit, testQuickAddReturnKeySaves), 1 übersprungen (iPad-Inspector, nur iPad), 1 fehlgeschlagen (Quick-Add-Audit). TodoCore `xcodebuild test` (macOS): 192 Tests, 22 übersprungen (Live), 0 Fehler. Builds iOS und macOS grün.

### Nachtrag Quick-Add-Audit und Thumbnail (07.11.2026)
- `testAccessibilityAuditQuickAdd` war auch auf `f84f055` (vor den UI-Paketen) rot, gleiche Meldung ("VerticalTextView is too small", 370 x 54,7 pt): keine Regression der UI-Pakete, sondern ein älterer Befund. Behoben: Beschreibungsfeld im `QuickAddSheet` mit `lineLimit(2...5)` und `frame(minHeight: TapTarget.minimum)` (Identifier unverändert). Danach 3 von 3 Läufen grün; ganze Klasse: 7 Tests, 6 bestanden, 1 übersprungen (iPad), 0 Fehler. `lineLimit(1...3)` mit minHeight allein reichte nicht.
- Thumbnail: `RemoteImage` zeigt Bilder mit einer Kantenlänge unter 16 px (z. B. das 1x1-px-Demobild) als neutralen Platzhalter mit Foto-Symbol statt als aufgezogenen Farbblock. Nur gebaut, nicht erneut angesehen.
- Builds iOS und macOS nach den Änderungen grün.

## Nachher: Für dich, lange Antworten (08.11.2026, Branch `ui-fuerdich-fix`, Basis `001c710`)

Methode: iPhone 18 Pro (iOS 27.0, eigener Simulator), Backend `.build/debug/App` (SQLite, Port 28795), Demodaten per `testSeedDemoData` mit neuem Schalter `TODO_LIVE_SEED_LONG=1` (Rückfrage mit 170-Zeichen-Option und Kompositum-Option, Freitext-Rückfrage, beantwortete Rückfrage mit mehrzeiliger Antwort). Alles per DEBUG-Deep-Link (`TODO_DEBUG_SELECT=feed`, neu: `TODO_DEBUG_FEED_POSTS=1` blendet "Braucht dich" aus, weil `simctl` nicht scrollen kann). Screenshots (900 px) in `docs/screenshots/fuerdich/`.

**Ursache (vorher, `iphone-before-feed-light.png`):** `FlowLayout` (CommandCenterParts) maß jede Antwort-Kapsel mit `.unspecified` und platzierte sie ebenso. Lange Optionen wurden dadurch einzeilig in Idealbreite (weit über den Bildschirm) und `lineLimit(2)` griff nie. Die Kapseln (`.bordered` auf getönter Karte) waren zudem grau auf grau.

**Behoben:**
- `FlowLayout` schlägt jedem Kind die verfügbare Breite vor und platziert mit der gemessenen Größe: lange Texte brechen um und enden mit Auslassung, nichts wird breiter als die Karte (betrifft Für dich und Steuerzentrale/`QuestionAnswerView`).
- Neuer `AnswerChipStyle`: Markentönung 12 %, 1-pt-Markenrahmen, Primärtext, Radius.m, mindestens 44 pt, `lineLimit(3)` mit Tail-Truncation. Ersetzt die blassen Kapseln; die Hauptaktion einer Karte (Annehmen) bleibt gefüllt.
- Für dich: Beschreibung/Antwort einer Karte `lineLimit(2)` bis `(3)`, Frage `lineLimit(5)`, Metazeile `lineLimit(2)`; volle Antwort im Detail (Tipp auf die Karte). Symbole der Karten auf `.subheadline`, damit das Sprechblasen-Symbol nicht aus der 24-pt-Spalte ragt.
- Previews "Feed lange Antworten" (Light, Dark, accessibility5).

**Gesehen (nachher):** `iphone-after-feed-light.png` (lange Optionen umbrechen, 3. Zeile mit "…", Kompositum trennt am Silbenende), `iphone-a-feed-dark.png`, `iphone-a-feed-light-ax.png` (accessibility-extra-large, nichts abgeschnitten außer Meta mit Auslassung), `iphone-after-feed-posts-light.png` (beantwortete Rückfrage: Antwort 2 Zeilen mit "…"). Weitere Seiten angesehen: Heute (`iphone-a-today-light.png`), Steuerzentrale (`...a-cc-light.png`), Projekt (`...a-project-light.png`), Aufgabendetail (`...a-task-light.png`), Konto (`...a-account-light.png`): keine zu breiten Elemente, kein abgeschnittener Text im Standardzustand.

**Beobachtet, nicht geändert:** Aufgabendetail: unter einem Erinnerungs-Chip steht wegen der 44-pt-Trefferfläche eine hohe Leerzeile; Senden-Pfeil (deaktiviert) blass; Tab-Leiste überlagert beim Scrollen Text (iOS-26-Material); Steuerzentrale-Spalte "Läuft" (leer) neben breiten Karten wirkt unruhig.

**Lücken:** nur iPhone; iPad und macOS nicht angesehen (macOS nur gebaut); Steuerzentrale-Tab "Fragen" und Listenmodus mit den neuen Kapseln nicht angesehen (gleiche Komponente); Dunkel/AX nur Für dich; Heute, Task, Konto nur hell/medium; kein echtes Tippen/Scrollen.
