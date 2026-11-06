#!/usr/bin/env python3
"""Creating decks, including that a new deck reaches desktop Anki by normal sync."""
from harness import Report, build, steps
from peer import Desktop, PASSWORD, URL, USER, start_server

ARGS = ("--sync-url", URL, "--sync-user", USER, "--sync-pass", PASSWORD)
build()
server = start_server()
r = Report()


def detail(doc, i=-1):
    return doc["steps"][i]["detail"]


try:
    d = steps("open;seed;create-deck:Spanish;state", reset=True)
    r.need_ok(d, "created a deck")
    r.check("new deck is listed", "Spanish" in detail(d, -2).split(","), detail(d, -2))
    r.check("new deck is selected and empty", detail(d) == "Spanish|0,0,0|done", detail(d))

    d = steps("open;state")
    r.check("selection survives a restart", detail(d).startswith("Spanish|"), detail(d))

    d = steps("open;create-deck:spanish;state;deck:Default;create-deck:   ;state")
    r.need_ok(d, "reused a name and ignored a blank one")
    r.check("existing name makes no duplicate", sum(n.lower().startswith("spanish") for n in detail(d, 1).split(",")) == 1, detail(d, 1))
    r.check("existing name selects that deck", detail(d, 2).startswith("Spanish|"), detail(d, 2))
    r.check("blank name changes nothing", detail(d).startswith("Default|"), detail(d))

    d = steps("open;create-deck:Languages::French;state")
    r.need_ok(d, "created a subdeck")
    names = detail(d, -2).split(",")
    r.check("subdeck and parent exist", "Languages" in names and "Languages::French" in names, names)
    r.check("subdeck is selected", detail(d).startswith("Languages::French|"), detail(d))

    d = steps("open;seed-bulk:25;deck:Default;easy:20;tap:customStudy;custom:preview:1;create-deck:Custom Study Session::Child")
    r.check("can't nest under a filtered deck", not d["steps"][-1]["ok"] and len(detail(d)) > 10, detail(d))
    d = steps("open;deck:Default;state;integrity;check")
    r.need_ok(d, "database intact")

    # A refresh still loading the first card page overlaps the switch to the empty deck, and
    # must not put the older deck's card back. This only fails some of the time, so it repeats.
    bad = [detail(d) for d in (steps("open;seed;create-deck:Spanish;state", reset=True) for _ in range(30)) if detail(d) != "Spanish|0,0,0|done"]
    r.check("overlapping refreshes end on the newest deck", not bad, bad)

    # A new deck must sync normally, not force a full sync.
    dk = Desktop()
    dk.add("desktop note")
    r.check("desktop full upload", dk.sync("upload"))
    d = steps("open;login;sync:download", *ARGS, reset=True)
    r.need_ok(d, "app downloaded")
    d = steps("open;restore-login;create-deck:From iPhone::Sub;sync")
    r.need_ok(d, "app created a deck and synced")
    r.check("no prompt needed", detail(d) == "none", detail(d))
    r.check("desktop needed no full sync", not dk.sync())
    r.check("desktop got the deck", dk.col.decks.id_for_name("From iPhone::Sub") is not None, dk.col.decks.all_names_and_ids())
    dk.col.close()
finally:
    server.kill()
r.finish()
