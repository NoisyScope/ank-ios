#!/usr/bin/env python3
"""Undo in the Study screen, including where it has to stop: at work that has synced."""
from harness import Report, build, steps
from peer import Desktop, PASSWORD, URL, USER, start_server

ARGS = ("--sync-url", URL, "--sync-user", USER, "--sync-pass", PASSWORD)
build()
server = start_server()
r = Report()


def detail(doc, i=-1):
    return doc["steps"][i]["detail"]


try:
    d = steps("open;seed;undo-label;card-text;state;review:1;undo-label;revlog;undo;revlog;card-text;state;undo-label", reset=True)
    r.need_ok(d, "answered a card and undid it")
    v = [s["detail"] for s in d["steps"]]
    r.check("nothing to undo at first", v[2] == "" or v[2] == "Add Note", v[2])
    r.check("button appears after an answer", v[6] != "" and "Answer" in v[6], v[6])
    r.check("review was recorded", v[7] == "1", v[7])
    r.check("undo removes the review", v[9] == "0", v[9])
    r.check("same card comes back", v[10] == v[3], f"{v[3]!r} {v[10]!r}")
    r.check("counts go back", v[11] == v[4], f"{v[4]} {v[11]}")

    d = steps("open;review:3;undo;undo;undo;revlog;state")
    r.need_ok(d, "undid three answers in a row")
    r.check("all three are gone", detail(d, -2) == "0", detail(d, -2))
    r.check("all cards are back", "|4,0,0|" in detail(d), detail(d))

    d = steps("open;easy:4;state;undo;state")
    r.need_ok(d, "undid the last answer of the deck")
    r.check("deck was finished", detail(d, 2).endswith("|done"), detail(d, 2))
    r.check("the finished page can undo too", detail(d).endswith("|cards"), detail(d))

    d = steps("open;add-card:Basic||Undo me^x;undo-label;undo", )
    r.check("undo offers the added note", detail(d, -2) == "Add Note", detail(d, -2))
    d = steps("open;undo-label")
    r.check("undo doesn't survive a restart", detail(d) == "", detail(d))

    d = steps("open;integrity;check")
    r.need_ok(d, "database intact")
    r.check("database has no problems", detail(d) == "no problems", detail(d))

    # With sync: an undone answer must never reach the other side, and a synced one can't be undone.
    dk = Desktop()
    dk.add("one")
    dk.add("two")
    dk.add("three")
    r.check("desktop full upload", dk.sync("upload"))
    d = steps("open;auto:off;idle:3;login;sync:download", *ARGS, reset=True)
    r.need_ok(d, "app downloaded")

    d = steps("open;auto:off;idle:3;restore-login;review:1;undo;sync;integrity")
    r.need_ok(d, "answered, undid and synced")
    r.check("no full sync needed", not dk.sync())
    r.check("undone answer never reaches desktop", dk.count("revlog") == 0, dk.count("revlog"))

    d = steps("open;auto:off;idle:3;restore-login;review:1;undo-label;sync;undo-label;integrity")
    r.need_ok(d, "answered and synced")
    r.check("undo available before syncing", detail(d, -4) != "", detail(d, -4))
    r.check("undo gone once synced", detail(d, -2) == "", detail(d, -2))
    dk.sync()
    r.check("synced answer reached desktop", dk.count("revlog") == 1, dk.count("revlog"))
    dk.col.close()
finally:
    server.kill()
r.finish()
