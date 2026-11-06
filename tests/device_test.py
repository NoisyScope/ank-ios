#!/usr/bin/env python3
"""Runs the checks on a real iPhone in a Release build with the test runner included. Keep the phone unlocked.
Run with Anki's Python: build/anki/out/pyenv/bin/python tests/device_test.py"""
import json, os, shutil, subprocess, sys, time
from pathlib import Path
from harness import ROOT, BUNDLE, Report
from peer import Desktop, PASSWORD, PORT, USER, Collection, fill, start_server

DEVICE = os.environ.get("DEVICE") or sys.exit("Set DEVICE to the iPhone's UDID, from: xcrun devicectl list devices")
OUT = ROOT / "build/device"
OUT.mkdir(parents=True, exist_ok=True)
LARGE = ROOT / "build/large.colpkg"
NOTES = 100_000


def run(*a, check=True):
    p = subprocess.run(a, capture_output=True, text=True)
    if check and p.returncode:
        sys.exit(f"failed: {' '.join(map(str, a[:6]))}\n{(p.stdout + p.stderr)[-500:]}")
    return p


def devicectl(*a, check=True):
    return run("xcrun", "devicectl", "device", *a, check=check)


def launch(*args):
    devicectl("process", "launch", "--device", DEVICE, "--terminate-existing", BUNDLE, *args)


def fetch(name):
    dest = OUT / name
    dest.unlink(missing_ok=True)
    ok = devicectl("copy", "from", "--device", DEVICE, "--domain-type", "appDataContainer", "--domain-identifier", BUNDLE,
                   "--source", f"Documents/{name}", "--destination", str(dest), check=False).returncode == 0
    return dest if ok and dest.exists() else None


def push(path, name):
    devicectl("copy", "to", "--device", DEVICE, "--domain-type", "appDataContainer", "--domain-identifier", BUNDLE,
              "--source", str(path), "--destination", f"Documents/{name}")


def steps(script, *args, timeout=240, reset=False):
    launch(*(["--reset"] if reset else []), "--steps", script, *args)
    want = len(script.split(";"))
    end = time.time() + timeout
    time.sleep(2)
    while time.time() < end:
        f = fetch("steps.json")
        if f:
            try:
                doc = json.loads(f.read_text())
                if len(doc["steps"]) >= want and [s["step"] for s in doc["steps"]][:want] == script.split(";"):
                    return doc
            except ValueError:
                pass
        time.sleep(2)
    sys.exit(f"timed out: {script}\n{(OUT / 'steps.json').read_text()[-500:] if (OUT / 'steps.json').exists() else ''}")


def ms(doc, name):
    return next(s for s in doc["steps"] if s["step"].startswith(name))["ms"]


def install():
    r = run("xcodebuild", "-project", str(ROOT / "AnkiStudy.xcodeproj"), "-scheme", "AnkiStudy", "-configuration", "Release",
            "-destination", f"id={DEVICE}", "-derivedDataPath", str(ROOT / "build/dd-device"), "-allowProvisioningUpdates",
            *([f"DEVELOPMENT_TEAM={os.environ['DEVELOPMENT_TEAM']}"] if os.environ.get("DEVELOPMENT_TEAM") else []),
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS=SELFTEST", "build", check=False)
    if r.returncode:
        sys.exit("\n".join(l for l in r.stdout.splitlines() if "error:" in l)[:1500] or "build failed")
    devicectl("install", "app", "--device", DEVICE, str(ROOT / "build/dd-device/Build/Products/Release-iphoneos/AnkiStudy.app"))


if not LARGE.exists():
    d = ROOT / "build/large-col"
    d.mkdir(exist_ok=True)
    col = Collection(str(d / "collection.anki2"))
    fill(col, NOTES)
    col.export_collection_package(str(LARGE), include_media=False, legacy=False)

install()
r = Report()

dead = fetch("auto.txt")
launch("--auto", "--reset")
time.sleep(3)
end = time.time() + 90
text = ""
while time.time() < end:
    f = fetch("auto.txt")
    text = f.read_text() if f else ""
    if "RESULT" in text and f.stat().st_mtime >= 0 and "unicode card" in text:
        break
    time.sleep(3)
print(text)
r.check("web checks on iPhone", "RESULT: 0 failed" in text)
for n in ("1-question.png", "2-answer.png", "3-math.png", "5-graphs.png"):
    fetch(n)

d = steps("open;seed;idle:0", reset=True)
push(LARGE, "large.colpkg")
d = steps("open;import:large.colpkg;deck:Subject 0;bench;review:20;integrity;check")
r.need_ok(d, "100k collection imported and reviewed")
bench = next(s for s in d["steps"] if s["step"] == "bench")["detail"]
print(f"  import {ms(d, 'import')} ms, {bench}, 20 reviews {ms(d, 'review')} ms, check {ms(d, 'check')} ms", flush=True)
r.check("all notes arrived", d["facts"]["notes"] == NOTES, d["facts"])

d = steps("open;close;open;bench")
r.need_ok(d, "reopen on iPhone")
print(f"  fresh launch open {d['steps'][0]['ms']} ms, close {d['steps'][1]['ms']} ms", flush=True)

# Sync over the network, if this phone can reach the Mac.
ip = run("ipconfig", "getifaddr", "en0", check=False).stdout.strip()
if ip:
    server = start_server("0.0.0.0")
    try:
        url = f"http://{ip}:{PORT}/"
        dk = Desktop()
        for i in range(30):
            dk.add(f"network card {i}")
        dk.col.media.write_data("net.png", b"\x89PNG over the network")
        dk.sync("upload")
        print(f"  syncing over the network with {url}; allow Local Network if iOS asks", flush=True)
        d = steps("open;login;sync:download;review:5;add:from iphone;sync;integrity", "--sync-url", url, "--sync-user", USER, "--sync-pass", PASSWORD, timeout=150, reset=True)
        r.need_ok(d, "iPhone synced over the network")
        dk.sync()
        r.check("desktop got iPhone's work", dk.count("notes") == 31 and dk.count("revlog") == 5, f"notes {dk.count('notes')}, reviews {dk.count('revlog')}")
        r.check("iPhone got media", d["facts"]["media"] == 1, d["facts"])
        dk.col.close()
    finally:
        server.kill()
r.finish()
