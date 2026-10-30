# Todolino – Apple-Apps

Sichtbarer Produktname ist „Todolino“ (nur Anzeigename). Bundle-IDs, Target-/Modulnamen (`Todo-iOS`, `TodoCore`, `TodoRunner` ...), Repo-Name, Domain und API bleiben technisch „todo“.

SwiftUI für iPhone, iPad, Mac und Apple Watch, einschließlich Mac-Agenten-Runner.

Das Backend-/PWA-Repository ist das Hauptarbeitsrepo und die Source of Truth. Sein lokaler Pfad steht in .workspace.local.json unter mainRepo. Bei einem frischen Checkout diese ignorierte Datei mit mainRepo und appleRepo als absoluten Pfaden anlegen. Dort README.md, AGENTS.md und docs/STATUS.md lesen.

Stand und Prüfnachweise: `docs/STATUS.md`. Xcode-Projekt per `xcodegen generate` aus `project.yml` (`Todo.xcodeproj` ist ungetrackt). Abgleich mit den Apple Human Interface Guidelines: `docs/HIG-AUDIT.md`.
