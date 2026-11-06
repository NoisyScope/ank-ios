#!/usr/bin/env python3
"""What protects a real collection: automatic sync, long syncs, repair and restore."""
import os, subprocess, time
from harness import Report, SIM, build, docs, launch, steps
from peer import Desktop, PASSWORD, URL, USER, start_server

ARGS = ("--sync-url", URL, "--sync-user", USER, "--sync-pass", PASSWORD)
build()
server = start_server()
r = Report()


def detail(doc, i=-1):
    return doc["steps"][i]["detail"]


try:
    dk = Desktop()
    for i in range(1500):
        dk.add(f"note {i}")
    r.check("desktop full upload", dk.sync("upload"))
    d = steps("open;login;sync:download", *ARGS, reset=True, timeout=120)
    r.need_ok(d, "app downloaded")

    # Automatic: a normal launch syncs without a tap, and leaving the app sends work.
    dk.add("made on desktop")
    dk.sync()
    launch()
    time.sleep(5)
    d = steps("open;idle:0")
    r.check("opening the app brings changes", d["facts"]["notes"] == 1501, d["facts"])

    # The wait lets the sync that runs on opening pass by before signing in, so only leaving
    # can send this. Without it that sync carries the note and hides a broken leaving sync.
    steps("open;idle:3;restore-login;add:left behind")
    dk.sync()
    r.check("nothing is sent before leaving", dk.count("notes") == 1501, dk.count("notes"))
    subprocess.run(["xcrun", "simctl", "launch", SIM, "com.apple.Preferences"], capture_output=True)
    full = False
    for _ in range(30):  # slower machines need longer than a laptop
        time.sleep(1)
        full = dk.sync() or full
        if dk.count("notes") == 1502:
            break
    r.check("leaving the app needs no full sync", not full)
    stopped = "Sync stopped because the app was in the background" in (docs() / "app.log").read_text()
    if os.environ.get("CI") and stopped and dk.count("notes") == 1501:
        # GitHub's simulators give very little background time. The phone test covers the real
        # allowance, so here it must stop safely and finish on the next sync.
        d = steps("open;auto:off;idle:3;restore-login;manual-sync")
        r.check("stopped sync can finish", detail(d) == "error=", detail(d))
        dk.sync()
        r.check("the note arrives on the next sync", dk.count("notes") == 1502, dk.count("notes"))
        steps("open;auto:on")
    else:
        r.check("leaving the app sends changes", dk.count("notes") == 1502, dk.count("notes"))

    d = steps("open;auto:off;idle:3;restore-login;add:stays here")
    subprocess.run(["xcrun", "simctl", "launch", SIM, "com.apple.Preferences"], capture_output=True)
    time.sleep(3)
    dk.sync()
    r.check("turning it off stops it", dk.count("notes") == 1502, dk.count("notes"))
    d = steps("open;manual-sync")
    r.check("manual sync still works", detail(d) == "error=", detail(d))

    # A full sync never starts by itself, and the app shows where to answer it.
    dk.schema_change()
    dk.sync("upload")
    d = steps("open;auto:on;auto-sync;tab")
    r.check("automatic sync waits at a conflict", "prompt=conflict" in detail(d, 2), detail(d, 2))
    r.check("question opens the Sync tab", detail(d) == "2", detail(d))
    d = steps("open;restore-login;sync:download")
    r.need_ok(d, "conflict resolved by the user")

    # Stays awake through a sync.
    dk.add("wake")
    dk.sync()
    d = steps("open;keep-awake")
    r.check("screen stays on during a sync, then not", detail(d) == "during=true after=false", detail(d))

    # Out of background time partway through: stops safely and can be finished.
    dk.schema_change()
    dk.sync("upload")
    d = steps("open;suspend-download;integrity;check")
    r.need_ok(d, "collection intact after stopping")
    r.check("says what happened, or finished first", d["steps"][1]["detail"] == "" or "background" in detail(d, 1), detail(d, 1))
    d = steps("open;restore-login;sync:download;integrity")
    r.need_ok(d, "sync finishes afterwards")
    r.check("all notes arrive", d["facts"]["notes"] == dk.count("notes"), d["facts"])

    # Offline: quiet when automatic, explained when asked.
    server.kill()
    server.wait()
    d = steps("open;auto-sync;manual-sync")
    r.check("automatic sync is quiet offline", "error=|" in detail(d, 1), detail(d, 1))
    r.check("manual sync explains", len(detail(d)) > 10, detail(d)[:80])

    # Check Database repairs, and forcing makes the next sync full.
    d = steps("open;seed;add:keep me;make-backup;backups", reset=True)
    r.need_ok(d, "made a backup")
    r.check("backup is listed", detail(d).endswith(".colpkg"), detail(d))
    before = d["facts"]["notes"]
    d = steps("open;add:later one;add:later two;restore-latest;integrity;check")
    r.need_ok(d, "restored the backup")
    r.check("collection goes back", d["facts"]["notes"] == before, d["facts"])
    r.check("restoring keeps a backup of what it replaced", d["facts"]["backups"] >= 2, d["facts"])
    r.check("restored file is still there", detail(steps("open;backups")).count(".colpkg") >= 2)

    d = steps("open;orphan;check-db;check")
    r.need_ok(d, "ran Check Database")
    r.check("reports the repair", "No problems" not in detail(d, 2), detail(d, 2))
    r.check("collection is clean after", detail(d) == "no problems", detail(d))

    server = start_server()
    dk.col.close()
    dk = Desktop("desktop2")
    dk.add("fresh")
    dk.sync("upload")
    d = steps("open;login;sync:download;force-full;integrity", *ARGS, reset=True)
    r.need_ok(d, "forced a full sync")
    r.check("forcing leads to the choice", detail(d, 3) == "conflict", detail(d, 3))
    dk.col.close()
finally:
    server.kill()
r.finish()
