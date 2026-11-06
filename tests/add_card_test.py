#!/usr/bin/env python3
"""Adding notes through the app's Add Card model, including that they reach desktop Anki."""
from harness import Report, build, steps
from peer import Desktop, PASSWORD, URL, USER, start_server

ARGS = ("--sync-url", URL, "--sync-user", USER, "--sync-pass", PASSWORD)
SEP = "\x1f"
build()
server = start_server()
r = Report()


def detail(doc, i=-1):
    return doc["steps"][i]["detail"]


def result(doc, i=-1):
    return dict(p.split("=", 1) for p in detail(doc, i).split("|") if "=" in p)


try:
    d = steps("open;create-deck:Biology;add-card:||What is ATP?^Energy <carrier> & more\nline two|bio  cell;last-note;state", reset=True)
    r.need_ok(d, "added a note to a new deck")
    a, note = result(d, -3), detail(d, -2).split("|")
    r.check("reports one card", a["status"] == "Added 1 card", a)
    r.check("defaults to the current deck", a["defaults"] == "Basic>Biology", a["defaults"])
    r.check("typed symbols stay plain text", note[0] == f"What is ATP?{SEP}Energy &lt;carrier&gt; &amp; more<br>line two", note[0])
    r.check("tags saved", note[1].split() == ["bio", "cell"], note[1])
    r.check("fields clear and tags stay", a["left"] == "^" and a["tags"] == "bio  cell", a)
    r.check("new card appears in the deck", detail(d) == "Biology|1,0,0|cards", detail(d))

    d = steps("open;create-deck:Symbols;add-card:||2 < 3 & <b>4</b>^x;card-text")
    r.check("card shows what was typed", detail(d) == "2 < 3 & <b>4</b>", detail(d))

    # Adding to a finished deck swaps pages while refreshes overlap, which only went wrong
    # some of the time, so it repeats.
    bad = [x for x in (detail(steps("open;seed;create-deck:Sym;add-card:||one two^x;card-text", reset=True)) for _ in range(25)) if x != "one two"]
    r.check("new card shows on a finished deck", not bad, bad)
    steps("open;create-deck:Biology;add-card:||What is ATP?^Energy|bio;idle:0", reset=True)

    d = steps("open;deck:Default;add-card:Basic (and reversed card)|Biology|Hello^Bonjour;last-note;state")
    r.need_ok(d, "added a reversed note to another deck")
    note = detail(d, -2).split("|")
    r.check("makes two cards", result(d, -3)["status"] == "Added 2 cards" and note[2] == "2", d["steps"][-3])
    r.check("adding elsewhere leaves the study deck", detail(d).startswith("Default|"), detail(d))

    d = steps("open;add-card:Cloze||{{c1::Paris}} is in {{c2::France}};last-note")
    r.need_ok(d, "added a cloze note")
    r.check("one card per deletion", detail(d).split("|")[2] == "2", detail(d))

    d = steps("open;add-card:Cloze||No deletions here")
    r.check("missing cloze warns", "cloze" in result(d)["warning"] and result(d)["status"] == "", result(d))
    d = steps("open;add-card:Cloze||No deletions here|||force;last-note")
    r.check("can add past the warning", result(d, -2)["status"].startswith("Added") and "No deletions" in detail(d), detail(d))

    d = steps("open;add-card:Basic||{{c1::nope}}^back")
    r.check("cloze refused on a basic note", "cloze note types" in result(d)["error"], result(d))
    d = steps("open;add-card:Basic||^only the back")
    r.check("empty first field refused", result(d)["error"] == "The first field is empty.", result(d))
    d = steps("open;add-card:Basic||   ^back")
    r.check("blank first field refused", result(d)["error"] == "The first field is empty.", result(d))

    before = steps("open;idle:0")["facts"]["notes"]
    d = steps("open;add-card:Basic||What is ATP?^again")
    r.check("duplicate warns", "already exists" in result(d)["warning"], result(d))
    r.check("warning adds nothing", d["facts"]["notes"] == before, d["facts"])
    d = steps("open;add-card:Basic||What is ATP?^again|||force")
    r.check("can add a duplicate anyway", d["facts"]["notes"] == before + 1, d["facts"])

    d = steps("open;sticky:Basic;add-card:Basic||Kept^Cleared")
    r.need_ok(d, "added with a sticky field")
    r.check("sticky field carries over", result(d)["left"] == "Kept^", result(d)["left"])

    # A filtered deck can't take new notes, so it must not be offered.
    d = steps("open;seed-bulk:25;deck:Default;easy:20;tap:customStudy;custom:preview:1;add-card:Basic||Unique one^b")
    a = result(d)
    r.check("filtered deck not offered", "Custom Study Session" not in a["offered"], a["offered"])
    r.check("from a filtered deck, adds elsewhere", a["status"].startswith("Added") and "Custom" not in a["defaults"], a)
    d = steps("open;deck:Default;integrity;check")
    r.need_ok(d, "database intact")

    dk = Desktop()
    dk.add("desktop note")
    r.check("desktop full upload", dk.sync("upload"))
    d = steps("open;login;sync:download", *ARGS, reset=True)
    r.need_ok(d, "app downloaded")
    d = steps("open;restore-login;create-deck:Phone;add-card:Basic||From the phone^a < b|phone;sync")
    r.need_ok(d, "app added a note and synced")
    r.check("sync needs no prompt", detail(d) == "none", detail(d))
    r.check("desktop needed no full sync", not dk.sync())
    ids = dk.col.find_notes("tag:phone")
    r.check("desktop got the note", len(ids) == 1, ids)
    n = dk.col.get_note(ids[0])
    r.check("desktop sees the same text", n["Back"] == "a &lt; b", n["Back"])
    r.check("desktop has it in the deck", dk.col.card_count() == 2 and len(dk.col.find_cards('deck:Phone')) == 1)
    dk.add("reply from desktop")
    dk.sync()
    d = steps("open;restore-login;sync;integrity;check")
    r.need_ok(d, "synced back")
    r.check("app got desktop's note", d["facts"]["notes"] == 3, d["facts"])
    dk.col.close()
finally:
    server.kill()
r.finish()
