# Todo – Einstieg für Coding-Agenten

Dies ist das Apple-Repository. Lies zuerst .workspace.local.json und dann AGENTS.md, docs/STATUS.md und docs/ARBEITSPLAN.md im dort genannten mainRepo. Globale Dokumentation liegt ausschließlich im Hauptrepository. Lokaler Stand: docs/STATUS.md.

## Projektgedächtnis

Das Backend-/PWA-Repository ist kanonisch. Vor nichttrivialer Arbeit STATUS, aktiven Arbeitsplan, PRODUKT, relevante Architektur-/Rechtedokumente und ADRs lesen. Tatsächlichen Code, Git-Status und laufende Prozesse prüfen. Alte Chatverläufe oder private Agent-Memory sind keine Voraussetzung zur Fortsetzung.

Apple hält nur seinen lokalen Status, Einrichtung und plattformspezifische Übergaben separat. API-Verträge liegen im Hauptrepository unter contracts/. Keine unabhängig gepflegten globalen Konzeptkopien.

## Verbindlich: Sessions sind wegwerfbar

Das Repository ist die Source of Truth. Ein frischer Agent muss allein aus den versionierten Dokumenten, Verträgen und dem tatsächlichen Code weiterarbeiten können. Chatverlauf, Session-IDs und persönliche Agent-Memory dürfen dafür keine Voraussetzung sein.

Dokumentation während der Arbeit aktuell halten: neue Nutzerentscheidungen vor abhängiger Umsetzung festhalten; nach jedem abgeschlossenen Teilschritt Status und Arbeitsplan mit Änderungen, Prüfungen und nächstem Schritt aktualisieren. Wesentliche Architekturentscheidungen als ADR dokumentieren. Globale Auswirkungen aus dem Apple-Repo auch im Hauptrepo festhalten.

Vor Übergabe, Kontextwechsel oder Sessionende einen konsistenten Checkpoint schreiben: Ziel, tatsächlich implementierter Stand, betroffene Repositories/Branches, ungesicherte Änderungen, Vertrags-/Migrationsfolgen, ausgeführte Tests und deren Grenzen, offene Probleme, laufende Prozesse sowie nächster konkreter Schritt. Keine erledigte Arbeit ausschließlich im Chat dokumentieren. Widersprüche zwischen Doku und Code auflösen oder ausdrücklich als offen kennzeichnen.

## Regeln

- Nutzerentscheidungen haben Vorrang; Annahmen und Vorschläge als solche dokumentieren.
- Code, technische Bezeichner, Kommentare und Tests auf Englisch; nutzerseitige Texte zunächst auf Deutsch und über Lokalisierungsressourcen.
- Genau zwei Produkt-Repositories. Backend und PWA bleiben zusammen.
- REST, MCP und Apps verwenden dieselben Fachregeln; keine umgehbaren Rechteprüfungen.
- Konto-, Team-, Projekt-, OAuth- und Runner-Grenzen explizit prüfen.
- Referenzprojekte nicht verändern; keine pauschale Kopie ihrer Fachmodelle.
- Vorhandene Änderungen erhalten; keine destruktiven Bereinigungen für einen sauberen Status.
- Keine Secrets, Tokens, privaten Laufzeitdaten oder vollständigen Chats ins Repository.
- Keine automatischen Pushes, Veröffentlichungen oder Deployments aus einer bloßen Implementierungsaufgabe ableiten.
- Routineentscheidungen selbst treffen; nur bei tatsächlich blockierenden Unklarheiten nachfragen.
- Keine Subagenten oder parallelen Schreiber ohne expliziten Auftrag. Wenn später autorisiert: getrennte Worktrees und klare Dateiverantwortung.

## Umsetzung und Abnahme

Zuerst ausführbaren vertikalen Schnitt herstellen. Relevante Änderungen mit passenden Tests prüfen; unnötige Tests und unbelegte Erfolgsaussagen vermeiden. Bei Backendänderungen Linux/MariaDB und bei nativen Änderungen betroffene Apple-Targets berücksichtigen. Fehlende Geräte-/Infrastrukturprüfungen offen nennen.

Vor Übergabe festhalten: Ziel, tatsächliche Änderungen, Branch/Commit, Vertrags-/Migrationsfolgen, ausgeführte Prüfungen, offene Fehler, laufende Jobs und nächster Schritt. Status und Arbeitsplan im selben Arbeitsschritt aktualisieren. Wesentliche Architekturänderungen als ADR begründen.
