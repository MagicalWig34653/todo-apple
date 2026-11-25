# Apple – lokaler Arbeitsplan

Globale Planung bleibt ausschließlich im Hauptrepository. Dieser Checkpoint beschreibt nur den beauftragten Runner-Arbeitsstrom im Worktree `/private/tmp/claude-501/runner-wt`, Branch `feature/runner`.

- [x] Hauptrepo-Vorgaben nur lesend prüfen, lokale Entscheidungen festhalten.
- [x] Eigenständiges Package und abstrakte Agent-/Servergrenzen anlegen.
- [x] Lokalen Zustand, Freigaben, Prozessstart und Zustandsübergänge implementieren (Validierung offen).
- [ ] Fake-Tests: Wiederanlauf, doppelte Starts, Lease-Verlust, Stop, Rückfragen und Persistenz.
- [ ] `swift build`, `swift test`, echter CLI-Read/Resume-Test mit `RUNNER_LIVE=1`.
- [ ] Grenzen und nächsten Integrationsschritt dokumentieren, Commit versuchen; kein Push.

Entscheidung aus dem Auftrag: keine echte HTTP-Anbindung vor Festlegung des parallel entwickelten Serververtrags. Lokale Pfade werden nicht an `RunnerServer` übergeben. Bei unklarer Prozessidentität nach Neustart keine PID-Signale und kein automatischer Neustart; expliziter Abgleich bleibt erforderlich.

## iPad-Detail-Audit 25.11.2026 (Karte ADD2CA8B)
- [x] Rot reproduziert, Ursache belegt, Fix und Test (f3ff1ed, e18de52), 12 Laeufe in Folge gruen; Details: STATUS, Nachtrag 25.11.
- [ ] Eigene Karte CDDE2F5C: `BrainUITests/test1_ConsentRecordSendAndAnswer` wackelt (schon auf 7d5aef8).
- Keine API-/Servermigration, kein TestFlight, Hauptrepo unveraendert.

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

## Review-Fixes 17.11.2026 – Befund 5
- Branch `codex/review-fixes`; Ziel: Review 1–9, hoch zuerst. Bestätigt: Outbox-Schreibvorgänge werfen Speicherfehler und nehmen fehlgeschlagene Enqueues im Speicher zurück. App bestätigt erst nach Speicherung, meldet lokalisierten Speicherfehler und behält Planung. Übergabe aus Sync-Queue löscht erst nach dauerhafter Outbox-Adoption. Bestehende Testaufrufe an throws angepasst; Auth-Mock vervollständigt.
- Regressionstest zuerst geschrieben, danach minimaler Fix; ausschließlich statisch gelesen. Auf Nutzeranweisung keine Builds, Tests, Netzaufrufe oder Pushes. Keine eigenen Jobs gestartet. Prozessinventar wegen Sandbox nicht lesbar.
- Keine API-/Servermigration; nur Apple-Repository geändert. Nächster Schritt: nächster Befund, abschließend `BERICHT-FIXES.md` und Prüfung durch Aufrufer.

## Review-Fixes 17.11.2026 – Befund 6
- Branch `codex/review-fixes`; Ziel: Review 1–9, hoch zuerst. Bestätigt: initiales Detail-Laden übernimmt Serverwerte nur für währenddessen unveränderte Felder. Bearbeitete Felder samt Basisversion bleiben bestehen; XCTest deckt Teilbearbeitung und unveränderten Entwurf ab.
- Regressionstest zuerst geschrieben, danach minimaler Fix; ausschließlich statisch gelesen. Auf Nutzeranweisung keine Builds, Tests, Netzaufrufe oder Pushes. Keine eigenen Jobs gestartet. Prozessinventar wegen Sandbox nicht lesbar.
- Keine API-/Servermigration; nur Apple-Repository geändert. Nächster Schritt: nächster Befund, abschließend `BERICHT-FIXES.md` und Prüfung durch Aufrufer.

## Review-Fixes 17.11.2026 – Befund 7
- Branch `codex/review-fixes`; Ziel: Review 1–9, hoch zuerst. Bestätigt: Chat sendet einen unveränderlichen Textstand und leert nur den noch identischen Entwurf. Regression verzögert die Antwort und schreibt währenddessen die nächste Nachricht.
- Regressionstest zuerst geschrieben, danach minimaler Fix; ausschließlich statisch gelesen. Auf Nutzeranweisung keine Builds, Tests, Netzaufrufe oder Pushes. Keine eigenen Jobs gestartet. Prozessinventar wegen Sandbox nicht lesbar.
- Keine API-/Servermigration; nur Apple-Repository geändert. Nächster Schritt: nächster Befund, abschließend `BERICHT-FIXES.md` und Prüfung durch Aufrufer.

## Review-Fixes 17.11.2026 – Befund 8
- Branch `codex/review-fixes`; Ziel: Review 1–9, hoch zuerst. Bestätigt: fehlgeschlagene Chat-Aufträge behalten unveränderlichen Text und Idempotenzschlüssel getrennt vom Composer. Gleicher Inhalt wiederholt denselben Auftrag; bearbeiteter Inhalt erhält einen neuen Schlüssel. Regression prüft verlorene Antwort, unveränderten Retry, Bearbeitung und Rückkehr zum Original.
- Regressionstest zuerst geschrieben, danach minimaler Fix; ausschließlich statisch gelesen. Auf Nutzeranweisung keine Builds, Tests, Netzaufrufe oder Pushes. Keine eigenen Jobs gestartet. Prozessinventar wegen Sandbox nicht lesbar.
- Keine API-/Servermigration; nur Apple-Repository geändert. Nächster Schritt: nächster Befund, abschließend `BERICHT-FIXES.md` und Prüfung durch Aufrufer.

## Review-Fixes 17.11.2026 – Befund 9
- Branch `codex/review-fixes`; Ziel: Review 1–9, hoch zuerst. Bestätigt: Brain-Aufträge vor Versand atomar als konto-/servergetrenntes Manifest speichern; Aufnahmen in Application Support übernehmen. Wiederöffnung stellt fehlgeschlagene Aufträge mit UUID/Dateireferenz wieder her. Bestätigung oder Verwerfen entfernt Manifest-Eintrag und Audio; Start räumt unterbrochene Dateilöschung nach. Keine Backend-/Vertragsänderung. Regression: Offline-Text, Audio, Wiederöffnung, Konto-/Serverisolation, Verwerfen.
- Regressionstest zuerst geschrieben, danach minimaler Fix; ausschließlich statisch gelesen. Auf Nutzeranweisung keine Builds, Tests, Netzaufrufe oder Pushes. Keine eigenen Jobs gestartet. Prozessinventar wegen Sandbox nicht lesbar.
- Keine API-/Servermigration; nur Apple-Repository geändert. Nächster Schritt: nächster Befund, abschließend `BERICHT-FIXES.md` und Prüfung durch Aufrufer.

## Übergabe 17.11.2026 – Review-Fixes 1–9
- Alle neun Befunde am Code bestätigt und bearbeitet; zwölf Regressionstests zuerst geschrieben, keine ausgeführt. Ein deutscher Commit je Befund auf `codex/review-fixes`; genaue Hashes und Testbefehle: `BERICHT-FIXES.md`.
- Statische Quell-/Git-Durchsicht und `git diff --check` ohne Befund. Keine Builds, Tests, Netzaufrufe, Pushes oder eigenen Jobs. Prozessinventar sandboxbedingt unbekannt. Keine Vertrags-/Servermigration, Hauptrepo nur gelesen.
- Neues macOS-XCTest-Target muss vom Aufrufer mit XcodeGen erzeugt werden. Ungebundene alte Tokens nicht migriert: erneute Anmeldung nötig. Brain-Manifest zusätzlich, bestehende Sync-/Outbox-Pfade unverändert.
- `.workspace.local.json` fehlt hier; Originaldatei verweist auf veraltete Documents-Pfade. Hauptrepo unter `~/Development/PhpstormProjects/todo` gelesen.
- Keine bekannten verbleibenden Implementierungsbefunde aus 1–9; Kompilierung, Testausführung, Gerät/Keychain/Sandbox bleiben ausdrücklich offen. Alle beauftragten Änderungen einschließlich Bericht werden lokal committet. Nächster Schritt: Aufrufer führt Befehle im Bericht und betroffene Apple-Builds aus.
