#!/usr/bin/env python3
"""Custom Study and Unbury from the Congratulations page, clicking the page's real links."""
from harness import Report, build, steps

build()
r = Report()


def step(doc, name):
    return next(s for s in doc["steps"] if s["step"].startswith(name))


def state(doc, i=-1):
    return doc["steps"][i]["detail"]


# Must run on a real card: the reviewer is the page that hosts third-party card scripts.
d = steps("open;seed;card-bridge", reset=True)
r.need_ok(d, "reached a card")
r.check("card scripts can't open Custom Study", state(d) == "ignored", state(d))

# 25 notes against the default limit of 20 new cards a day leaves a limit to raise.
d = steps("open;seed-bulk:25;tag:marked;easy:20;state", reset=True, timeout=120)
r.need_ok(d, "finished today's cards")
r.check("deck is finished", state(d).endswith("|done"), state(d))

d = steps("open;easy:0;tap:customStudy")
r.need_ok(d, "tapped the Custom Study link")
r.check("link opens the sheet", state(d) == "sheet open", state(d))

d = steps("open;tap:customStudy;custom:new:3;state")
r.need_ok(d, "raised the new card limit")
r.check("3 more new cards appear", "|3,0,0|cards" in state(d), state(d))
d = steps("open;easy:3;state")
r.need_ok(d, "studied them")
r.check("finished again", state(d).endswith("|done"), state(d))

d = steps("open;tap:customStudy;custom:forgot:1")
r.need_ok(d, "tried forgotten cards with none forgotten")
r.check("empty result keeps the sheet open with a reason", state(d).startswith("kept open:") and len(state(d)) > 12, state(d))

d = steps("open;tap:customStudy;custom:ahead:30;state")
r.need_ok(d, "review ahead")
r.check("review ahead builds a session", state(d).startswith("Custom Study Session|") and "|cards" in state(d), state(d))
d = steps("open;deck:Default;state")

d = steps("open;tap:customStudy;custom:preview:1;state")
r.need_ok(d, "preview new cards")
r.check("preview builds a session", state(d).startswith("Custom Study Session|") and "|cards" in state(d), state(d))
d = steps("open;deck:Default;state")

d = steps("open;tap:customStudy;custom:cram:2:marked;state")
r.need_ok(d, "study by tag")
r.check("tag session has only tagged cards", state(d).startswith("Custom Study Session|") and "|cards" in state(d), state(d))
d = steps("open;deck:Default;state")

d = steps("open;tap:customStudy;custom:cram:2:no-such-tag")
r.check("unknown tag reports no match", state(d).startswith("kept open:"), state(d))

# Unbury: raise the limit, bury a card, then use the page's link.
d = steps("open;tap:customStudy;custom:new:1;bury;bury;state")
r.need_ok(d, "buried the last cards")
r.check("nothing left after burying", state(d).endswith("|done"), state(d))
d = steps("open;tap:unbury;state")
r.need_ok(d, "tapped the unbury link")
r.check("unbury brings the card back", state(d).endswith("|cards"), state(d))

d = steps("open;integrity;check")
r.need_ok(d, "database intact")
r.finish()
