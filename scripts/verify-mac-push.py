#!/usr/bin/env python3
"""Payloads and checks of scripts/mac-push-e2e.sh (card D97C4918).

  verify-mac-push.py prepare <origin> <token> <pushes.json> <expected.json>   payloads in the backend's format
  verify-mac-push.py check <out dir>                                         compares report.json with expected.json
"""
import json
import os
import sys
import urllib.request
import uuid


def prepare(origin, token, pushes_path, expected_path):
    def get(path):
        request = urllib.request.Request(origin + path, headers={"Authorization": "Bearer " + token})
        with urllib.request.urlopen(request, timeout=15) as response:
            return json.load(response)

    project = next(p for p in get("/v1/projects") if p["name"] == "Website-Relaunch")
    task = next(t for t in get("/v1/tasks") if t["projectID"] == project["id"] and t["title"] == "Design-Review vorbereiten")
    request_id = get("/v1/feed")["confirmations"][-1]["id"]
    pid, tid = project["id"].upper(), task["id"].upper()

    def payload(kind, category, **ids):
        return {"aps": {"alert": {"title": "Todolino", "body": "Etwas wartet."}, "category": category, "badge": 1}, "kind": kind, **ids}

    ids = {"projectID": pid, "taskID": tid}
    subject = str(uuid.uuid4()).upper()
    pushes = [
        ("reminder", payload("reminder", "TODO_REMINDER", **ids), f"project({pid})", task["title"]),
        ("comment", payload("comment", "TODO_COMMENT", subjectID=subject, **ids), f"project({pid})", task["title"]),
        ("question", payload("question", "TODO_QUESTION", subjectID=subject, **ids), f"projectCommandCenter({pid})", task["title"]),
        ("review", payload("review", "TODO_REVIEW", subjectID=subject, **ids), f"projectCommandCenter({pid})", task["title"]),
        ("action_request", payload("action_request", "TODO_CONFIRMATION", subjectID=request_id.upper()), "feed", ""),
        ("daily_brief", payload("daily_brief", "TODO_DAILY_BRIEF"), "commandCenter", ""),
    ]
    with open(pushes_path, "w") as f:
        json.dump([{"name": n, "payload": p} for n, p, _, _ in pushes], f)
    with open(expected_path, "w") as f:
        json.dump({n: {"selection": s, "task": t} for n, _, s, t in pushes}, f, indent=1)


def check(out):
    report = json.load(open(os.path.join(out, "report.json")))
    expected = json.load(open(os.path.join(out, "expected.json")))
    fails = []
    if not report["policyProhibited"] or report["appActive"] or report["windowOnScreen"]:
        fails.append(f"window not isolated: {report['policyProhibited']=} {report['appActive']=} {report['windowOnScreen']=}")
    if len(report["pushes"]) != 2 * len(expected):
        fails.append(f"{len(report['pushes'])} deliveries, expected {2 * len(expected)}")
    for got in report["pushes"]:
        want = expected[got["name"]]
        # "Optional(Todo.SidebarItem.project(<uuid>))": compare the last case with its payload.
        selection = got["selection"].removeprefix("Optional(").removesuffix(")") if got["selection"].startswith("Optional(") else got["selection"]
        selection = selection.split("SidebarItem.")[-1]
        ok = selection.upper() == want["selection"].upper() and got["task"] == want["task"]
        if not os.path.getsize(os.path.join(out, got["file"])) > 10_000:
            ok = False
        print(("ok   " if ok else "FAIL ") + f"{got['file']}: {selection} task={got['task']!r}")
        if not ok:
            fails.append(f"{got['file']}: expected {want}, got {selection} / {got['task']!r}")
    for fail in fails:
        print("FAIL:", fail)
    print(f"mac-push: {len(report['pushes'])} deliveries, {len(fails)} failures")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    if sys.argv[1] == "prepare":
        prepare(*sys.argv[2:6])
    else:
        check(sys.argv[2])
