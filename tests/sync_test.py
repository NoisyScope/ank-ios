#!/usr/bin/env python3
"""Phase 1: a collection round-trips between the iOS app and desktop Anki through a sync server.
Run with Anki's Python: build/anki/out/pyenv/bin/python tests/sync_test.py"""
from harness import Report, build, docs, steps
from peer import Desktop, PASSWORD, URL, USER, start_server

ARGS = ("--sync-url", URL, "--sync-user", USER, "--sync-pass", PASSWORD)
build()
server = start_server()
r = Report()


def step(doc, name):
    return next(s for s in doc["steps"] if s["step"].startswith(name))


try:
    # Wrong password leaves no token behind.
    d = steps("open;login", "--sync-url", URL, "--sync-user", USER, "--sync-pass", "wrong", reset=True)
    r.check("wrong password rejected", not step(d, "login")["ok"], step(d, "login")["detail"])
    d = steps("open;restore-login")
    r.check("no token stored after failure", step(d, "restore-login")["detail"] == "no token")

    # Desktop starts with content; the server is empty, so it uploads.
    dk = Desktop()
    for i in range(20):
        dk.add(f"desktop note {i}" + (f'<img src="dk{i}.png">' if i < 3 else ""))
    for i in range(3):
        dk.col.media.write_data(f"dk{i}.png", b"\x89PNG desktop %d" % i)
    r.check("desktop full upload", dk.sync("upload"))

    # A fresh app must ask before downloading, and cancelling changes nothing.
    d = steps("open;login;sync:cancel", *ARGS, reset=True)
    r.need_ok(d, "app login and first sync")
    r.check("empty app asks before download", step(d, "sync")["detail"] == "confirmDownload", step(d, "sync")["detail"])
    r.check("cancel leaves app empty", d["facts"]["notes"] == 0, d["facts"])

    d = steps("open;restore-login;sync:download;check")
    r.need_ok(d, "token persisted and full download ran")
    r.check("download brought notes", d["facts"]["notes"] == 20, d["facts"])
    r.check("download brought media", d["facts"]["media"] == 3, d["facts"])
    r.check("backup made before download", d["facts"]["backups"] >= 1, d["facts"])

    # Normal changes on the app reach desktop.
    d = steps("open;restore-login;review:5;add:from ios;add-media:ios.png;sync;check")
    r.need_ok(d, "app reviewed, added and synced")
    r.check("normal sync needs no prompt", step(d, "sync")["detail"] == "none", step(d, "sync")["detail"])
    r.check("desktop needed no full sync", not dk.sync())
    r.check("desktop got app's notes", dk.count("notes") == 22, dk.count("notes"))
    r.check("desktop got app's reviews", dk.count("revlog") == 5, dk.count("revlog"))
    r.check("desktop got app's media", "ios.png" in dk.media(), dk.media())
    r.check("media content intact", open(dk.col.media.dir() + "/ios.png", "rb").read() == b"ios media ios.png")

    # Normal changes on desktop reach the app.
    dk.add("second from desktop")
    dk.col.media.write_data("dk9.png", b"\x89PNG later")
    dk.sync()
    d = steps("open;restore-login;sync;check")
    r.need_ok(d, "app synced desktop's changes")
    r.check("app got desktop's note", d["facts"]["notes"] == 23, d["facts"])
    r.check("app got desktop's media", (docs() / "anki/media/dk9.png").read_bytes() == b"\x89PNG later")

    # Both sides change independently and merge.
    dk.add("merge from desktop")
    dk.sync()
    d = steps("open;restore-login;add:merge from ios;sync;check")
    r.need_ok(d, "both sides changed, app merged")
    dk.sync()
    r.check("merge kept both notes", d["facts"]["notes"] == 25 and dk.count("notes") == 25, f"app {d['facts']['notes']}, desktop {dk.count('notes')}")

    # Conflict: cancelling keeps local work, and download replaces it after a backup.
    dk.schema_change()
    dk.sync("upload")
    d = steps("open;restore-login;add:only on ios;sync:cancel")
    r.check("conflict asks the user", step(d, "sync")["detail"] == "conflict", step(d, "sync")["detail"])
    r.check("cancel keeps local note", d["facts"]["notes"] == 26, d["facts"])
    backups = d["facts"]["backups"]
    d = steps("open;restore-login;sync:download;check")
    r.need_ok(d, "conflict resolved by download")
    r.check("download matches server", d["facts"]["notes"] == 25, d["facts"])
    r.check("backup made before replacing", d["facts"]["backups"] > backups, d["facts"])

    # Conflict resolved the other way: the app's collection wins.
    dk.schema_change()
    dk.sync("upload")
    d = steps("open;restore-login;add:ios wins;sync:upload;check")
    r.need_ok(d, "conflict resolved by upload")
    r.check("desktop saw a required full sync", dk.sync("download"))
    r.check("desktop has app's note", dk.count("notes") == 26, dk.count("notes"))

    # After all that, both sides agree and a sync is a no-op.
    d = steps("open;restore-login;sync;integrity;check")
    r.need_ok(d, "final sync")
    r.check("final state agrees", d["facts"]["notes"] == dk.count("notes") and d["facts"]["revlog"] == dk.count("revlog"), f"{d['facts']}")
    r.check("final media agrees", d["facts"]["media"] == len(dk.media()), f"app {d['facts']['media']}, desktop {len(dk.media())}")
    dk.col.close()
finally:
    server.kill()
r.finish()
