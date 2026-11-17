# Apple – lokaler Arbeitsplan

Globale Planung bleibt ausschließlich im Hauptrepository. Dieser Checkpoint beschreibt nur den beauftragten Runner-Arbeitsstrom im Worktree `/private/tmp/claude-501/runner-wt`, Branch `feature/runner`.

- [x] Hauptrepo-Vorgaben nur lesend prüfen, lokale Entscheidungen festhalten.
- [x] Eigenständiges Package und abstrakte Agent-/Servergrenzen anlegen.
- [x] Lokalen Zustand, Freigaben, Prozessstart und Zustandsübergänge implementieren (Validierung offen).
- [ ] Fake-Tests: Wiederanlauf, doppelte Starts, Lease-Verlust, Stop, Rückfragen und Persistenz.
- [ ] `swift build`, `swift test`, echter CLI-Read/Resume-Test mit `RUNNER_LIVE=1`.
- [ ] Grenzen und nächsten Integrationsschritt dokumentieren, Commit versuchen; kein Push.

Entscheidung aus dem Auftrag: keine echte HTTP-Anbindung vor Festlegung des parallel entwickelten Serververtrags. Lokale Pfade werden nicht an `RunnerServer` übergeben. Bei unklarer Prozessidentität nach Neustart keine PID-Signale und kein automatischer Neustart; expliziter Abgleich bleibt erforderlich.

## Review-Fixes 17.11.2026 – Befund 1
- Branch `codex/review-fixes`; Ziel: Review 1–9, hoch zuerst. Bestätigt: unveränderlicher Client, Origin-getrennte Keychain-Einträge und Generation vor Login-Veröffentlichung; Recovery ebenfalls gebunden. Alte ungebundene Tokens werden bewusst nicht migriert (erneute Anmeldung nötig). macOS-XCTest-Target ergänzt.
- Regressionstest zuerst geschrieben, danach minimaler Fix; ausschließlich statisch gelesen. Auf Nutzeranweisung keine Builds, Tests, Netzaufrufe oder Pushes. Keine eigenen Jobs gestartet. Prozessinventar wegen Sandbox nicht lesbar.
- Keine API-/Servermigration; nur Apple-Repository geändert. Nächster Schritt: nächster Befund, abschließend `BERICHT-FIXES.md` und Prüfung durch Aufrufer.

## Review-Fixes 17.11.2026 – Befund 2
- Branch `codex/review-fixes`; Ziel: Review 1–9, hoch zuerst. Bestätigt: SyncEngine dauerhaft invalidiert, verspätete Feed-/Mutationsantworten vor Persistierung abgewiesen; App-Veröffentlichung durch Sitzungsgeneration und Engine-Identität geschützt. REST-Leser und Outbox ebenfalls abgegrenzt.
- Regressionstest zuerst geschrieben, danach minimaler Fix; ausschließlich statisch gelesen. Auf Nutzeranweisung keine Builds, Tests, Netzaufrufe oder Pushes. Keine eigenen Jobs gestartet. Prozessinventar wegen Sandbox nicht lesbar.
- Keine API-/Servermigration; nur Apple-Repository geändert. Nächster Schritt: nächster Befund, abschließend `BERICHT-FIXES.md` und Prüfung durch Aufrufer.

## Review-Fixes 17.11.2026 – Befund 3
- Branch `codex/review-fixes`; Ziel: Review 1–9, hoch zuerst. Bestätigt: 401 beendet und invalidiert die Sitzung ohne lokale Queue-/Metadatenlöschung. Erneute Anmeldung öffnet denselben server-/kontogebundenen Store; explizites Abmelden verwirft wie bisher. Regression prüft Wiederöffnung samt Outbox.
- Regressionstest zuerst geschrieben, danach minimaler Fix; ausschließlich statisch gelesen. Auf Nutzeranweisung keine Builds, Tests, Netzaufrufe oder Pushes. Keine eigenen Jobs gestartet. Prozessinventar wegen Sandbox nicht lesbar.
- Keine API-/Servermigration; nur Apple-Repository geändert. Nächster Schritt: nächster Befund, abschließend `BERICHT-FIXES.md` und Prüfung durch Aufrufer.

## Review-Fixes 17.11.2026 – Befund 4
- Branch `codex/review-fixes`; Ziel: Review 1–9, hoch zuerst. Bestätigt: Textentwurf behält Basisversion; nur geänderte Felder werden gesendet. Engine weist veraltete Entwurfsversion vor dem Enqueue als Versionskonflikt ab; späterer Serverkonflikt bleibt über bestehende Konflikt-Queue sichtbar. Entwurf bleibt bei Fehler erhalten.
- Regressionstest zuerst geschrieben, danach minimaler Fix; ausschließlich statisch gelesen. Auf Nutzeranweisung keine Builds, Tests, Netzaufrufe oder Pushes. Keine eigenen Jobs gestartet. Prozessinventar wegen Sandbox nicht lesbar.
- Keine API-/Servermigration; nur Apple-Repository geändert. Nächster Schritt: nächster Befund, abschließend `BERICHT-FIXES.md` und Prüfung durch Aufrufer.
