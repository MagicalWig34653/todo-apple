# Todo – App-Icon

Ruhige, abgerundete Projektkarten mit einem klaren Haken. Die drei diagonal
eingerückten Karten stehen für Projekt, Unterprojekt und Aufgabe. Blaugrün,
sanfte Verläufe und ein großzügiger Außenabstand unterstützen einen ruhigen,
verlässlichen Eindruck. Alle Quellen und PNGs haben eine Arbeitsfläche von
1024 × 1024 Pixeln im sRGB-Farbraum. Die Gestaltung ist ein Entwurf.

![Helle Vorschau](preview-light.png)

## Ebenen und Dateien

Die Reihenfolge in dieser Tabelle entspricht der Komposition von hinten nach vorn.
Jede SVG-Datei enthält eine benannte, separat editierbare Ebene und ihren Verlauf.
Es gibt keine Schriften, externen Bilder oder verknüpften Ressourcen.

| SVG-Quelle | PNG-Render | Funktion |
| --- | --- | --- |
| `background.svg` | `background.png` | Vollflächiger, vollständig deckender Hintergrund ohne vorgezeichnete Plattformmaske |
| `project-root.svg` | `project-root.png` | Hintere Projektkarte in hellem Blaugrün |
| `project-child.svg` | `project-child.png` | Eingerückte Unterprojektkarte in Petrol |
| `project-task.svg` | `project-task.png` | Helle vordere Aufgabenkarte |
| `checkmark.svg` | `checkmark.png` | Separater Haken mit runden Enden |

Alle vier Vordergrunddateien besitzen außerhalb ihrer Form Transparenz. Ihre
gemeinsame Arbeitsfläche hält die Positionen beim Übereinanderlegen stabil.
Die PNGs sind direkte Renderings der jeweiligen SVGs, keine zugeschnittenen Bilder.

Weitere Dateien:

- `preview-light.png`, `preview-dark.png`, `preview-tinted.png`: zusammengesetzte,
  statische Ansichten, jeweils 1024 × 1024 Pixel.
- `Todo.icon/icon.json`: Hintergrundfüllung, vier geordnete Gruppen mit je einer
  Bildebene, `image-name`, Ebenenfüllungen und Erscheinungsvarianten.
- `Todo.icon/Assets/`: Kopien von `project-root.png`, `project-child.png`,
  `project-task.png`, `checkmark.png`.
- `render.mjs`: Rendering und Prüfung der Pixelmaße/Transparenz.
- `render-info.json`: verwendete Werkzeugversionen und Prüfgrenzen.

## Icon Composer und Erscheinungsvarianten

Der Hintergrund wird im Bundle ausschließlich über die oberste `fill`-Eigenschaft
von `icon.json` definiert. `background.svg` und `background.png` dienen als
unabhängige Quelle beziehungsweise Renderdatei. Sie werden nicht zusätzlich als
Vordergrund eingebaut. So bleibt die Hintergrundfüllung in Icon Composer editierbar.
Die PNGs in `Assets/` liefern die Formen; die Füllungen in `icon.json` bestimmen
deren Farben pro Erscheinungsbild. Alle Ebenen behalten ihre Originalgröße und
Position, ohne zusätzliche Transformation.

- **Hell / Standard:** eisblauer Hintergrund, zwei blaugrüne Projektstufen,
  fast weiße Aufgabenkarte und petrolfarbener Haken. Die SVG-Farben entsprechen
  den Standardfüllungen des Manifests.
- **Dunkel:** explizite `appearance: dark`-Füllungen für Hintergrund und jede
  Ebene. Dunkles Petrol im Hintergrund, gedämpfte Projektkarten und eine helle
  Aufgabenkarte halten die Silhouette und den Haken erkennbar.
- **Tinted / Mono:** explizite `appearance: tinted`-Füllungen in abgestuften
  Grautönen bilden eine farbunabhängige Tonwertvorlage. `preview-tinted.png`
  zeigt diese Vorlage. Eine vom System gewählte Akzentfarbe, Mono Light/Clear
  sowie das tatsächliche Verhalten unter verschiedenen Hintergrundbildern
  sind damit nicht simuliert und müssen in Icon Composer geprüft werden.

Materialeffekte, Schatten, Specular und Transluzenz sind bewusst deaktiviert.
Die Tiefe entsteht aus den Karten und Farbwerten. Plattformen dürfen die äußere
Iconform maskieren; eine abgerundete App-Icon-Außenkontur ist nicht eingebrannt.
Das Manifest sieht eine gemeinsame quadratische Komposition und watchOS vor.
Insbesondere die kreisförmige Watch-Maske ist noch zu prüfen.

## PNGs reproduzieren

Verwendet wurde **Node.js mit Sharp 0.35.3**, libvips 8.18.3 und dessen
**librsvg 2.62.90** für die SVG-Rasterung. Die genaue Node-Version steht in
`render-info.json`. Es wurden keine Pakete installiert.

Aus dem Repository-Hauptverzeichnis, mit bereits auflösbarem Sharp:

```sh
node design/icon/render.mjs
```

In der hier verwendeten Umgebung liegt Sharp global und kann so geladen werden:

```sh
SHARP_MODULE=/opt/homebrew/lib/node_modules/sharp node design/icon/render.mjs
```

Auf anderen Rechnern `SHARP_MODULE` bei Bedarf auf die vorhandene Sharp-Installation
setzen. Das Skript schreibt ausschließlich in seinen eigenen Ordner: fünf PNGs,
die vier Bundle-Assets, drei Vorschauen und `render-info.json`. SVGs und Manifest
werden nicht überschrieben. Es prüft Pixelmaße sowie volle Hintergrunddeckung
und transparente/deckende Pixel in den Vordergrunddateien.

Die SVGs sind die Geometriequellen. Für Farbänderungen sowohl die beiden
`stop-color`-Werte der SVG als auch die entsprechenden sRGB-Werte unter `fill`
im Manifest anpassen; das Skript synchronisiert diese Quelldateien nicht.
Dunkel-/Tinted-Farben werden nur im Manifest gepflegt. Die Vorschauen übernehmen
diese Verläufe mit den SVG-Formen und bilden vertikale Verläufe ohne Apple-Effekte
nach. Nach Änderungen in Icon Composer dessen exportierte Vorschauen verwenden;
das Skript ist kein allgemeiner Renderer für beliebige Icon-Composer-Einstellungen.

## In Xcode verwenden

1. `Todo.icon` mit Icon Composer öffnen, beispielsweise über Xcode → Open
   Developer Tool → Icon Composer. Gruppenreihenfolge und Füllungen überprüfen,
   anschließend Hell, Dunkel und Mono einschließlich eigener Tönung sowie
   quadratische und kreisförmige Plattformmasken ansehen und speichern.
2. Das gesamte Paket `Todo.icon` aus dem Finder in den Project Navigator des
   gewünschten Xcode-Projekts ziehen und dem App-Target zuordnen. Bei Bedarf
   „Copy items“ wählen; das Apple-Repository wurde durch diesen Auftrag nicht verändert.
3. Unter Target → General → App Icons and Launch Screen im Feld App Icon
   **Todo** eintragen, also den Paketnamen ohne `.icon`.
4. Auf den betroffenen Simulatoren und echten Geräten bauen und die Darstellung
   in den Systemeinstellungen für Erscheinungsbild/Tönung prüfen. Auch kleine
   Darstellungen in Spotlight, Einstellungen und auf der Watch kontrollieren.

Falls die verwendete Composer-Version das handgeschriebene Manifest ablehnt:
ein neues Dokument anlegen, den Hintergrundverlauf einstellen und die vier
Vordergrund-PNGs in Tabellenreihenfolge importieren. Die Varianten anschließend
anhand der Manifestfarben konfigurieren und mit dieser Version neu speichern.

Quellen: Apples [Icon Composer](https://developer.apple.com/icon-composer/) und
[Anleitung für Erstellung und Xcode-Import](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer).
Die JSON-Struktur orientiert sich an den originalen Beispieldateien
[sample-01.json](https://github.com/peterpoliwoda/icon-composer-template/blob/main/Tests/IconComposerModelTests/Fixtures/sample-01.json)
und [sample-03.json](https://github.com/peterpoliwoda/icon-composer-template/blob/main/Tests/IconComposerModelTests/Fixtures/sample-03.json)
des Formatprojekts. Das ist eine empirische Formatreferenz, kein von Apple
veröffentlichtes, stabiles JSON-Schema. Es wurde keine fremde Grafik übernommen.

## Prüfstand und Übergabe

Stand: 27.10.2026. Ziel und Umsetzung sind die hier abgelegten Icon-Artefakte.
Ausgangsbranch `main`, Ausgangscommit `4a34f50`. Keine Git-Mutation, kein Commit,
kein Push und keine Änderung außerhalb von `design/icon/`. Daher bleiben die
globalen Status-/Arbeitsplandokumente entsprechend der Auftragsgrenze unverändert;
dieser Abschnitt hält den lokalen Checkpoint fest. Keine API-, Vertrags-,
Migrations- oder Laufzeitfolgen. Der abschließende Git-Status zeigte zusätzlich
Änderungen außerhalb dieses Ordners (unter anderem S3Store, Swarm-Dateien und
Web-Screenshots); diese wurden von diesem Auftrag nicht bearbeitet.

Erfolgreich ausgeführt: Rendering aller fünf Ebenen und drei Vorschauen,
Pixelmaß-/Alpha-Prüfung, JSON-Parsing, Prüfung der referenzierten Bundle-Bilder
und ihres Abgleichs mit den PNG-Renderings. Alle drei Vorschauen wurden visuell
betrachtet. Keine Dienste oder Hintergrundjobs durch diesen Auftrag gestartet.
Die allgemeine Prozessübersicht war durch die Sandbox gesperrt.

**Ungeprüft:** Das Paket wurde nicht in Icon Composer geöffnet oder gespeichert,
nicht mit Apples Compiler validiert und nicht in Xcode importiert oder gebaut.
JSON-Syntax und vorhandene Assets belegen keine Composer-Kompatibilität.
Die genauen Verlaufsrichtungen/Füllungsinterpretationen in Apple-Werkzeugen,
Systemtönung, Clear-/Mono-Light-Modi, Liquid-Glass-Verhalten, Plattformmasken,
kleine Icongrößen und echte Geräte bleiben offen. Sharp bildet Apples
Renderingpipeline nicht nach. Backend-/Apple-Tests sind für diese isolierten
Grafikdateien nicht ausgeführt worden.

Nächster konkreter Schritt: `Todo.icon` in der vorgesehenen Icon-Composer-Version
öffnen, Varianten und Plattformmasken prüfen und dort neu speichern; danach
Xcode-Import und Simulator-/Geräteprüfung durchführen.
