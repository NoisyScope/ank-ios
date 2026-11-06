#!/usr/bin/env python3
"""Phase 1: a large collection imports, opens, syncs and stays quick in a Release build.
Run with Anki's Python: build/anki/out/pyenv/bin/python tests/scale_test.py [notes]"""
import shutil, sys, time
from harness import Report, build, docs, steps
from peer import Desktop, PASSWORD, URL, USER, WORK, fill, start_server

NOTES = int(sys.argv[1]) if len(sys.argv) > 1 else 100_000
ARGS = ("--sync-url", URL, "--sync-user", USER, "--sync-pass", PASSWORD)
build("Release")
server = start_server()
r = Report()


def ms(doc, name):
    return next(s for s in doc["steps"] if s["step"].startswith(name))["ms"]


try:
    t = time.time()
    dk = Desktop()
    col = dk.col
    fill(col, NOTES)
    print(f"  built {dk.count('notes')} notes, {dk.count('revlog')} reviews in {time.time() - t:.0f}s", flush=True)

    pkg = WORK / "large.colpkg"
    col.export_collection_package(str(pkg), include_media=False, legacy=False)
    col.reopen()
    print(f"  package {pkg.stat().st_size / 1e6:.0f} MB", flush=True)

    steps("open", reset=True)
    shutil.copy(pkg, docs() / "large.colpkg")
    d = steps("open;import:large.colpkg;deck:Subject 0;bench;review:20;integrity;check", timeout=400)
    r.need_ok(d, "large colpkg imported and used")
    print(f"  import {ms(d, 'import')} ms, {next(s for s in d['steps'] if s['step'] == 'bench')['detail']}, 20 reviews {ms(d, 'review')} ms, check {ms(d, 'check')} ms", flush=True)
    r.check("all notes arrived", d["facts"]["notes"] == NOTES, d["facts"])
    r.check("import under 60s", ms(d, "import") < 60000, ms(d, "import"))
    r.check("deck list under 500ms", int(next(s for s in d["steps"] if s["step"] == "bench")["detail"].split("=")[1].split("ms")[0]) < 500)

    d = steps("open;close;open;bench")
    r.need_ok(d, "reopen")
    print(f"  fresh launch open {d['steps'][0]['ms']} ms, close {d['steps'][1]['ms']} ms, reopen {d['steps'][2]['ms']} ms", flush=True)
    r.check("open under 2s", d["steps"][0]["ms"] < 2000, d["steps"][0]["ms"])

    # Full sync of the large collection both ways.
    dk.sync("upload")
    d = steps("open;login;sync:download;integrity", *ARGS, timeout=400, reset=True)
    r.need_ok(d, "large full download")
    print(f"  full download {ms(d, 'sync')} ms", flush=True)
    r.check("downloaded every note", d["facts"]["notes"] == NOTES, d["facts"])
    before = d["facts"]["revlog"]
    d = steps("open;restore-login;deck:Subject 0;review:50;sync;integrity", timeout=200)
    r.need_ok(d, "normal sync on large collection")
    print(f"  normal sync after 50 reviews {ms(d, 'sync')} ms", flush=True)
    dk.sync()
    r.check("app really reviewed", d["facts"]["revlog"] == before + 50, f"{before} -> {d['facts']['revlog']}")
    r.check("desktop received the reviews", dk.count("revlog") == d["facts"]["revlog"], f"desktop {dk.count('revlog')}, app {d['facts']['revlog']}")
    col.close()
finally:
    server.kill()
r.finish()
