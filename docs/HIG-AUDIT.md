# HIG-Audit Todolino (Apple-Clients)

Stand 31.10.2026. Grundlage: Apple Human Interface Guidelines und Plattform-Best-Practices (aus dem Wissensstand; die HIG-Webseiten sind clientseitig gerendert und waren per WebFetch nicht auswertbar), Code-Review der Dateien unter `App/Shared`, Simulator-Läufe und XCUITest-Accessibility-Audit. Priorität: H = hoch, M = mittel, N = niedrig. Status: behoben, offen, Empfehlung (nicht gebaut, laut Auftrag).

| # | Bereich | Regel | Ist | Soll | Prio | Status |
|---|---|---|---|---|---|---|
| 1 | Navigation | Native Container statt Eigenbau | TabView (iPhone), NavigationSplitView (iPad/Mac), NavigationStack je Tab | vorhanden | - | ok |
| 2 | Navigation | Mac/iPad: Detail als Inspector | Aufgabendetail war überall ein Sheet | `.inspector` im Split-Layout (regular), Sheet nur compact | H | behoben |
| 3 | Menüleiste | Volle Menüs mit Standardkürzeln | Keine `Commands`; ⌘N doppelt belegt (Toolbar und Seitenleiste) | `CommandGroup`: Neue Aufgabe ⌘N, Neues Projekt ⇧⌘N, Suchen ⌘F, Aktualisieren ⌘R, Menü "Gehe zu" ⌘1-6; ⌘W, ⌘Z vom System | H | behoben |
| 4 | Menüleiste | Einstellungen ⌘, | Keine Settings-Szene | `Settings`-Szene (Konto, Server, Version, Abmelden) | M | behoben |
| 5 | Menüleiste | App-Menü zeigt Produktnamen | CFBundleName = "Todo-macOS" | `InfoPlist.xcstrings` (CFBundleName/DisplayName "Todolino") | H | behoben (siehe Rename) |
| 6 | Undo | ⌘Z / Schütteln für Erledigen | Kein Undo | `UndoManager` für Erledigen/Wieder öffnen (`AppModel.setDone`) | H | behoben |
| 7 | Undo | Löschen rückgängig | Server löscht per Tombstone; Wiederherstellung nicht im Vertrag | Bestätigung statt Undo: Kontextmenü fragt, Wischen ohne Volllauf | M | behoben (Ersatz) |
| 8 | Swipe | Destruktive Aktion nicht per Vollwisch | Volllauf-Wischen löschte sofort | `allowsFullSwipe: false` für Löschen/Verschieben, Erledigen (leading) bleibt Volllauf | H | behoben |
| 9 | Kontextmenü | Alle Swipe-Aktionen im Menü | vorhanden; Teilen fehlte | `ShareLink` ergänzt | M | behoben |
| 10 | Touch-Ziele | ≥ 44 pt | Checkbox 44 fest; Glocke, "+", Chips (~32 pt) klein | `tapTarget()` (44 pt Trefferfläche, optisch gleich) | H | behoben (Audit-Lauf prüft weiter) |
| 11 | Dynamic Type | Text skaliert, nichts abgeschnitten | 16 feste `.font(.system(size:))`, feste Größen (Checkbox, FAB, Icon-Kachel, Senden-Button), Metazeile einzeilig, Quick-Add-Chips kollabierten bei AX5 | Text-Styles, `@ScaledMetric`, Metazeile und Quick-Add-Leiste vertikal ab AX-Größen, `.large`-Detent ab AX | H | behoben (Aufgabenliste, Quick-Add; Detail/Steuerzentrale siehe 12) |
| 12 | Dynamic Type | Alle Screens bis AX5 | Detail, Steuerzentrale, Wochenstreifen, Quick-Add, Projektkopf, Seitenleiste, Suche per Screenshot bei AX5 geprüft; Kopfzeilen mehrzeilig/skalierend, Eigenschaftszeilen und Chips stapeln ab AX | je Screen prüfen | M | behoben (iPhone und iPad im Simulator; Board nur Kopf/Spalten gesehen) |
| 13 | VoiceOver | Zeile: Label, Wert, Trait, Aktionen | `.combine` verschluckte Checkbox, Priorität nur "P1" | Titel als Label, Wert (Status, Priorität, Fällig, Unteraufgaben, Labels, Projekt), `.isButton`, Aktionen Öffnen/Erledigen/Verschieben/Löschen | H | behoben |
| 14 | VoiceOver | Zähler-Badges | Seitenleisten-Zähler als lose Zahl | Label + Wert "n offen" je Zeile; Glocke mit Wert | H | behoben |
| 15 | VoiceOver | Tap-Gesten als Schaltflächen | `onTapGesture` ohne Trait (Favoriten, Aktivität, Runner-Jobs) | `.isButton` | M | behoben |
| 16 | VoiceOver | Auf-/Zuklapp-Zustand | "Mehr" ohne Zustand | Wert "Ausgeklappt/Eingeklappt" | M | behoben |
| 17 | Farbe | Nie einziges Signal | Priorität nur als Ringfarbe | Flaggen-Symbol plus "P1-P3" in der Metazeile, Priorität im VoiceOver-Wert, Fälligkeit mit Symbol und Text | H | behoben |
| 18 | Kontrast | WCAG AA (4,5:1 Text, 3:1 Grafik) | Brand 4,1:1; DueTomorrow 2,6:1; PriorityP2 2,6:1; `.tertiary`-Text ~2,1:1 | Farben abgedunkelt (Brand 5,2; Tomorrow 5,0; P2 3,7), Dunkelvarianten angehoben, `.tertiary` für Text durch `.secondary` ersetzt | H | behoben |
| 19 | Kontrast | Erhöhter Kontrast | Keine Varianten | Hoher-Kontrast-Varianten für alle Semantikfarben im Asset-Katalog | M | behoben (Sichtprüfung im Simulator) |
| 20 | Bewegung | Reduce Motion | Endlosanimationen in Leerzustand und Skeleton, Feder-Animationen | `accessibilityReduceMotion` respektiert (Leerzustand, Skeleton, Pressable, Häkchen, Abhaken) | H | behoben |
| 21 | Transparenz | Reduce Transparency | Nur System-Materialien (`.regularMaterial`) | System passt selbst an | - | ok |
| 22 | Eingabe | Return/Fokus/Feldtypen | Login: textContentType, submitLabel, Autokorrektur aus vorhanden; Quick-Add Return speichert, ⌘↩ speichert | vorhanden | - | ok |
| 23 | Sheets | Detents | Quick-Add feste Höhe 330 pt | `[.medium, .large]` mit ScrollView | M | behoben |
| 24 | Systemintegration | Teilen | Kein ShareLink | Aufgabe teilen (Kontextmenü) | M | behoben |
| 25 | Systemintegration | Drag und Drop | Aufgabenzeilen ziehbar; Ablegen auf Seitenleisten-Projekte: `dropDestination` für `.task` verschiebt per Sync-Queue (`task.update` mit `projectID`, offline-fähig); TodoCore-Test grün | Ablegen auf Seitenleisten-Projekte | M | behoben (Logik getestet; Gesten-Drag im XCUITest nicht auslösbar, siehe Bericht) |
| 26 | Systemintegration | `ContentUnavailableView` | `EmptyState` baut jetzt auf `ContentUnavailableView` | System-Komponente | N | behoben |
| 27 | Systemintegration | Haptik | alle Aufrufe laufen über `Haptics` -> ein `sensoryFeedback`-Host an der Wurzel, keine UIKit-Generatoren mehr | vereinheitlichen | N | behoben (Gefühl nicht am Gerät prüfbar) |
| 28 | Fenster | Mindestgröße, Stage Manager, Split View | Keine Mac-Mindestgröße | `frame(minWidth: 820, minHeight: 560)` Mac; iPad: Größenklasse schaltet Sheet/Inspector | M | behoben (Mac real gestartet) |
| 29 | Lokalisierung | Plural | Keine Plural-Varianten ("Team-Einladung(en)", "1 weitere Karten") | Stringkatalog-Pluralvarianten für Zähler-Texte | M | behoben |
| 30 | Fehler/Laden/Offline | Zustände sichtbar | Skeleton, Offline-/Wartend-Kapsel, Fehlerbanner, Alerts | vorhanden | - | ok |
| 31 | Datenschutz | Berechtigungen | `PrivacyInfo.xcprivacy`, Face-ID- und Lokalnetz-Text vorhanden; Fotos über PhotosPicker ohne Berechtigung | vorhanden | - | ok |
| 32 | Navigation | Zurück-Wischen | NavigationStack liefert Kantenwischen; Detail-Sheet per Ziehen schließbar | vorhanden | - | ok |
| 33 | Toolbar | iPhone: Aktion in Toolbar statt FAB | FAB bleibt (konventionell für Schnellerfassung, 60 pt skaliert); `contentMargins` hält die letzten Zeilen frei | Toolbar-Plus nur bei HIG-Begründung | N | Entscheidung: bleibt, begründet (häufigste Aktion, Daumenreichweite) |
| 34 | Tastatur iPad | Fokus-/Tab-Navigation, Kürzel | Kürzel über `Commands` auch auf iPad sichtbar | Fokus-Prüfung mit Hardwaretastatur offen | N | offen |

| 35 | Kontrast | Sekundärtext AA | System-`.secondary` ~3,4:1 | Asset `TextSecondary` (hell 5,9:1, dunkel hoch), überall statt `.secondary` | H | behoben |
| 36 | Kontrast | Restbefunde XCUITest-Audit | Chip "Morgen", Wochenstreifen, Label-Chips, Platzhalter (2,6:1), Lane-/Status-Farben (System-Blau/Orange/Rot/Grün) | Farben abdunkeln, Tönung 10 %, Textfarbe `TextSecondary`, neue Assets Purple/Teal, Platzhalter `TextSecondary`, Kategoriefarben aus Assets | M | behoben (Zahlen unten; Audit meldet Contrast weiter als Anhang, aber ohne harte Fehler) |
| 37 | Dynamic Type | Audit: Text evtl. abgeschnitten | Titelfeld Quick-Add jetzt mehrzeilig (Return speichert, XCUITest), Kopfzeilen skalieren, Wochenstreifen skaliert mit Zelle | Textstile, mehrzeilig | M | behoben (Screenshots AX5) |
| 38 | Test | UI-Test "Aufgabe anlegen, abhaken, Detail" | Ursache: kein App-Fehler. Die Aufgabe wurde gespeichert (Server: vorhanden), aber der Test suchte sie im Tab "Eingang"; Quick-Add aus "Heute" plant sie auf heute, "Eingang" listet nur Aufgaben ohne Datum. Zusätzlich war "Als erledigt markieren" doppelt vorhanden (Zeile + Aktion) | Test sucht in "Heute", eindeutige Aktion | M | behoben, 3x hintereinander grün (alle 5 UI-Tests) |

## Zahlen
38 Befunde: 11 ohne Mangel (ok), 25 behoben (12, 25, 26, 27, 36, 37, 38 neu), 1 bewusst belassen (33), 1 offen (34, Hardwaretastatur iPad). Hoch/mittel offen: 0.

## Kontrast-Rechnung (WCAG 2.x, relative Luminanz, Text auf Chip = Farbe über 10 % Eigentönung auf Canvas/CanvasRaised, schlechterer Wert)
Vorher (13 % Tönung, hell): Brand 4,3; Morgen (DueTomorrow) 4,2; P2 3,2; P3 4,0; Label-Chip-Text auf Palettentönung min 4,5. Platzhalter System ~2,6.
Nachher (Text 4,5:1 gefordert):

| Modus | Brand | Morgen | Heute | Überfällig | P2 | P3 | TextSecondary | Purple | Teal |
|---|---|---|---|---|---|---|---|---|---|
| hell | 4,6 | 4,6 | 4,7 | 4,6 | 4,6 | 4,6 | 4,7 | 4,6 | 4,6 |
| hell + hoher Kontrast | 6,0 | 5,8 | 6,6 | 6,3 | 4,6 | 5,6 | 7,3 | 7,0 | 7,0 |
| dunkel | 4,4 | 5,9 | 5,7 | 4,8 | 5,9 | 4,5 | 5,3 | 4,6 | 4,8 |
| dunkel + hoher Kontrast | 5,8 | 7,1 | 6,9 | 6,1 | 7,1 | 6,1 | 7,5 | 7,1 | 7,0 |

Ausnahme: Brand dunkel auf 10-%-Tönung 4,4:1 (knapp unter 4,5); weiter aufhellen würde das weiße Symbol auf dem FAB unter 3:1 drücken (3,0:1 heute). Offen, nur Chips mit Brand-Text im Dunkelmodus. Label-Chip-Text (TextSecondary auf Palettentönung): hell 4,5, dunkel 5,1, hoher Kontrast 7,3/7,5. Kachel-Farben (weißes Symbol, Grafik, 3:1): Grün 3,0, Orange 3,0, Teal 3,0, Blau 4,0. Platzhalter jetzt TextSecondary: gemessen 5,3:1 (Pixelprobe im Screenshot).

## Empfehlungen (nicht gebaut)
- Widgets (Heute-Liste, Zähler), Live Activity für laufende Agenten.
- App Intents: "Aufgabe hinzufügen", "Heute anzeigen", Spotlight-Indexierung (`CSSearchableItem`), Siri/Kurzbefehle, Steuerelemente.
- Benachrichtigungen (lokale Erinnerungen aus `reminders`, Push für Agenten-Rückfragen).
- Watch: Sitzungsübernahme, Komplikation mit Zähler.
- Ablegen von Aufgaben auf Seitenleisten-Projekte (Verschieben) und Mehrfachauswahl am Mac.
- Handoff/`NSUserActivity` für geöffnete Aufgabe.

## Verifikation
Siehe Abschnitt "Checkpoint 31.10.2026 HIG" in `docs/STATUS.md`.
