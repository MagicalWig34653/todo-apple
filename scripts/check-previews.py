#!/usr/bin/env python3
"""Every screen of the app has a #Preview (card A6B0D5E3). Run: python3 -I scripts/check-previews.py
A screen counts as covered when its name appears in the preview area of its file: everything from the first `#Preview` or the
first preview host (struct named *Preview*, *Host*, *Gallery*) to the end of the file. Exit 1 and a list if one is missing."""
import re, sys, os
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "App", "Shared")
SCREENS = {  # screen view -> file
    "LoginView": "LoginView.swift", "SplitLayout": "MainView.swift", "PhoneTabs": "MainView.swift", "PlanView": "MainView.swift",
    "InboxView": "MainView.swift", "TodayView": "AgendaView.swift", "UpcomingView": "AgendaView.swift",
    "ProjectView": "ProjectPage.swift", "ProjectsHome": "Sidebar.swift",
    "LabelsView": "Sidebar.swift", "LabelTasksView": "Sidebar.swift", "AccountView": "Sidebar.swift",
    "TaskDetailView": "TaskDetailView.swift", "BoardView": "BoardView.swift", "CommandCenterView": "CommandCenterView.swift",
    "OverviewNowView": "OverviewNowView.swift", "BrainContent": "BrainPreviews.swift", "CalendarScreen": "CalendarView.swift",
    "CalendarDetailSheet": "CalendarDetail.swift", "SearchView": "SearchView.swift", "TeamsView": "TeamsView.swift",
    "FeedView": "FeedView.swift", "SettingsView": "TodoApp.swift", "QuickAddSheet": "QuickAddSheet.swift",
    "ActivityView": "ServerViews.swift", "AgentsView": "ServerViews.swift", "ProjectCommentsView": "ServerViews.swift",
    "ReviewVariantsView": "ReviewVariantsView.swift", "ConversationView": "ConversationView.swift",
}
marker = re.compile(r"^#Preview|^(?:@MainActor )?(?:private |fileprivate )?(?:struct|func) \w*(?:Preview|Gallery|Host|preview)\w*", re.M)
missing = []
for screen, file in sorted(SCREENS.items()):
    text = open(os.path.join(ROOT, file)).read()
    if not re.search(rf"struct {screen}\b", text) and not re.search(rf"struct {screen}\b", "".join(open(os.path.join(ROOT, f)).read() for f in os.listdir(ROOT) if f.endswith(".swift"))):
        print(f"?? {screen}: view not found (list out of date)"); missing.append(screen); continue
    m = marker.search(text)
    area = text[m.start():] if m else ""
    if not re.search(rf"\b{screen}\b", area): missing.append(screen); print(f"MISSING preview: {screen} ({file})")
print(f"{len(SCREENS) - len(missing)}/{len(SCREENS)} screens with preview")
sys.exit(1 if missing else 0)
