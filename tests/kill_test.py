#!/usr/bin/env python3
"""Phase 0: the collection survives SIGKILL mid-review and suspension."""
import json, os, random, time
from harness import Report, build, docs, launch, stop, steps, sh, SIM, BUNDLE

ROUNDS = 12
build()
r = Report()


def burn(seconds, kill):
    """Answers cards for a while. Returns how many answers the app recorded."""
    (docs() / "burn.txt").unlink(missing_ok=True)
    pid = launch("--steps", "open;burn")
    time.sleep(seconds)
    if kill:
        os.kill(pid, 9)
    else:
        stop()
    time.sleep(0.3)
    f = docs() / "burn.txt"
    return int(f.read_text() or 0) if f.exists() else 0


def inspect():
    doc = steps("open;integrity;check;idle:0")
    by = {s["step"].split(":")[0]: s for s in doc["steps"]}
    return by["integrity"]["ok"] and by["integrity"]["detail"] == "ok", by["check"]["detail"], doc["facts"]["revlog"]


# Control: the same work with no SIGKILL, to tell ordinary reports from crash damage.
r.need_ok(steps("open;seed-bulk:300", reset=True, timeout=180), "control: created 300 notes")
burn(2, kill=False)
_, control, _ = inspect()
print(f"  control report with no kills: {control}", flush=True)

r.need_ok(steps("open;seed-bulk:300", reset=True, timeout=180), "created 300 notes")
total = baseline = 0
for i in range(ROUNDS):
    n = burn(random.uniform(1.2, 3.5), kill=True)
    ok, report, revlog = inspect()
    # An answer can commit just before the kill and never reach burn.txt, so revlog may run
    # ahead by a little. It must never fall behind what the app recorded.
    behind = baseline + n - revlog
    print(f"  round {i + 1}: recorded {n}, revlog {revlog}, report: {report}", flush=True)
    r.check(f"round {i + 1} SQLite integrity ok", ok)
    r.check(f"round {i + 1} no answers lost", behind <= 0, f"behind by {behind}" if behind > 0 else "")
    r.check(f"round {i + 1} report matches control", report.split(" to ")[0] == control.split(" to ")[0] or report == "no problems", report)
    total += n
    baseline = revlog

log = docs() / "app.log"
log.write_text("")
launch("--steps", "open;idle:40")
end = time.time() + 30
while time.time() < end and not ("collection opened" in log.read_text() and "app phase: active" in log.read_text()):
    time.sleep(0.2)
r.check("app becomes active", "app phase: active" in log.read_text(), log.read_text()[-200:])
began = time.time()
sh("xcrun", "simctl", "launch", SIM, "com.apple.Preferences")
print(f"Settings opened in {time.time() - began:.1f}s", flush=True)
end = time.time() + 60  # the first launch of Settings is slow on a fresh machine
while time.time() < end and "collection closed" not in log.read_text():
    time.sleep(0.2)
print(f"waited {time.time() - began:.1f}s for the collection to close", flush=True)
r.check("background closes the collection", "collection closed" in log.read_text(), log.read_text()[-300:])
sh("xcrun", "simctl", "launch", SIM, BUNDLE)
end = time.time() + 60
while time.time() < end and log.read_text().count("collection opened") < 2:
    time.sleep(0.2)
r.check("foreground reopens the collection", log.read_text().count("collection opened") >= 2)
stop()
ok, report, _ = inspect()
r.check("database intact after suspend cycle", ok, report)
print(f"total: {total} answers survived {ROUNDS} kills")
r.finish()
