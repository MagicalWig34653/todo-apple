# Apple – lokaler Arbeitsplan

Globale Planung bleibt ausschließlich im Hauptrepository. Dieser Checkpoint beschreibt nur den beauftragten Runner-Arbeitsstrom im Worktree `/private/tmp/claude-501/runner-wt`, Branch `feature/runner`.

- [x] Hauptrepo-Vorgaben nur lesend prüfen, lokale Entscheidungen festhalten.
- [x] Eigenständiges Package und abstrakte Agent-/Servergrenzen anlegen.
- [x] Lokalen Zustand, Freigaben, Prozessstart und Zustandsübergänge implementieren (Validierung offen).
- [ ] Fake-Tests: Wiederanlauf, doppelte Starts, Lease-Verlust, Stop, Rückfragen und Persistenz.
- [ ] `swift build`, `swift test`, echter CLI-Read/Resume-Test mit `RUNNER_LIVE=1`.
- [ ] Grenzen und nächsten Integrationsschritt dokumentieren, Commit versuchen; kein Push.

Entscheidung aus dem Auftrag: keine echte HTTP-Anbindung vor Festlegung des parallel entwickelten Serververtrags. Lokale Pfade werden nicht an `RunnerServer` übergeben. Bei unklarer Prozessidentität nach Neustart keine PID-Signale und kein automatischer Neustart; expliziter Abgleich bleibt erforderlich.
