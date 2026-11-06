"""Drives the app in the iOS Simulator through its --steps test runner."""
import json, os, signal, subprocess, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUNDLE = next(l for l in (ROOT / "Info.plist").read_text().split("<string>") if l.startswith("net.ankicoretest")).split("<")[0]


def sh(*a, check=True):
    return subprocess.run(a, check=check, capture_output=True, text=True).stdout.strip()


def pick_simulator():
    """The $SIM simulator, or a booted iPhone, or the first available one."""
    if os.environ.get("SIM"):
        return os.environ["SIM"]
    devices = json.loads(sh("xcrun", "simctl", "list", "devices", "available", "-j"))["devices"]
    phones = [d for group in devices.values() for d in group if d["name"].startswith("iPhone")]
    phones.sort(key=lambda d: d["state"] != "Booted")
    if not phones:
        sys.exit("no iPhone simulator found: add one in Xcode, or set SIM")
    return phones[0]["udid"]


SIM = pick_simulator()


def build(config="Debug"):
    """Builds and installs. Release includes the test runner, so timings reflect a shipping build."""
    extra = ["SWIFT_ACTIVE_COMPILATION_CONDITIONS=SELFTEST"] if config == "Release" else []
    # The sync tests store a token in the Keychain, which needs a signed build.
    if os.environ.get("DEVELOPMENT_TEAM"):
        extra.append(f"DEVELOPMENT_TEAM={os.environ['DEVELOPMENT_TEAM']}")
    r = subprocess.run(["xcodebuild", "-project", "AnkiStudy.xcodeproj", "-scheme", "AnkiStudy", "-configuration", config,
                        "-sdk", "iphonesimulator", "-destination", f"id={SIM}", "-derivedDataPath", "build/dd",
                        "-allowProvisioningUpdates", *extra, "build"], cwd=ROOT, capture_output=True, text=True)
    if r.returncode:
        sys.exit("\n".join(l for l in r.stdout.splitlines() if "error:" in l)[:3000] or "build failed")
    subprocess.run(["xcrun", "simctl", "boot", SIM], capture_output=True)
    sh("xcrun", "simctl", "bootstatus", SIM, "-b")
    stop()
    sh("xcrun", "simctl", "install", SIM, str(ROOT / f"build/dd/Build/Products/{config}-iphonesimulator/AnkiStudy.app"))


def stop():
    subprocess.run(["xcrun", "simctl", "terminate", SIM, BUNDLE], capture_output=True)


def docs():
    return Path(sh("xcrun", "simctl", "get_app_container", SIM, BUNDLE, "data")) / "Documents"


def launch(*args):
    """Starts the app and returns its pid."""
    stop()
    out = sh("xcrun", "simctl", "launch", SIM, BUNDLE, *args)
    return int(out.rsplit(":", 1)[1])


def steps(script, *args, timeout=120, reset=False):
    """Runs a step script to completion and returns the parsed steps.json."""
    f = docs() / "steps.json"
    f.unlink(missing_ok=True)
    launch(*(["--reset"] if reset else []), "--steps", script, *args)
    want = len(script.split(";"))
    end = time.time() + timeout
    while time.time() < end:
        try:
            doc = json.loads(f.read_text())
            if len(doc["steps"]) >= want:
                return doc
        except (OSError, ValueError):
            pass
        time.sleep(0.2)
    sys.exit(f"timed out or crashed: {script}\n{f.read_text()[-400:] if f.exists() else 'no steps.json'}")


class Report:
    def __init__(self):
        self.fails = 0

    def check(self, name, ok, detail=""):
        self.fails += not ok
        print(f"{'PASS' if ok else 'FAIL'} {name}{': ' + str(detail) if detail != '' else ''}", flush=True)

    def need_ok(self, doc, label):
        bad = [s for s in doc["steps"] if not s["ok"]]
        self.check(label, not bad, bad[0]["step"] + " -> " + str(bad[0]["detail"]) if bad else "")

    def finish(self):
        print(f"\nRESULT: {self.fails} failed")
        sys.exit(1 if self.fails else 0)
