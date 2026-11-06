#!/usr/bin/env python3
"""The web page and security checks from the app's --auto mode."""
import sys, time
from harness import build, docs, launch, steps

build()
f = docs() / "auto.txt"
f.unlink(missing_ok=True)
launch("--auto", "--reset")
end = time.time() + 60
while time.time() < end and not (f.exists() and "RESULT" in f.read_text()):
    time.sleep(0.3)
text = f.read_text() if f.exists() else "no result"
print(text)
log = (docs() / "app.log").read_text()
errors = [l for l in log.splitlines() if "jserror" in l or "jsreject" in l or "-> 404" in l]
print(f"js errors and 404s: {len(errors)}", *errors[:5], sep="\n")

# A normal launch must show the first card, which depends on the page being ready in time.
steps("open;seed;close", reset=True)
(docs() / "app.log").write_text("")
for i in range(8):
    launch()
    end = time.time() + 30  # slower machines need longer than a laptop
    while time.time() < end and (docs() / "app.log").read_text().count("collection opened") <= i:
        time.sleep(0.2)
    time.sleep(1)  # time for the card to show, or a script error to be logged
log = (docs() / "app.log").read_text()
opened, bad = log.count("collection opened"), [l[:160] for l in log.splitlines() if "js error" in l]
print(f"normal launches: {opened}, script errors: {len(bad)}", *bad[:3], sep="\n")
sys.exit(0 if "RESULT: 0 failed" in text and not errors and opened >= 8 and not bad else 1)
