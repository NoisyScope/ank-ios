#!/usr/bin/env python3
"""A desktop collection exported for older versions, with spoken cards, and text file import."""
import shutil
from harness import Report, build, docs, steps
from peer import Desktop, WORK, start_server
from anki.collection import DeckIdLimit

build()
server = start_server()
r = Report()


def detail(doc, i=-1):
    return doc["steps"][i]["detail"]


try:
    dk = Desktop()
    col = dk.col
    m = col.models.new("Speech")
    for f in ("DE", "ES"):
        col.models.add_field(m, col.models.new_field(f))
    t = col.models.new_template("Card 1")
    t["qfmt"] = '<div class="q">{{DE}}</div>{{tts de_DE voices=Apple_Anna_(Premium) speed=1.2:DE}}'
    t["afmt"] = "{{FrontSide}}<hr id=answer>{{ES}}{{tts es_ES:ES}}"
    col.models.add_template(m, t)
    col.models.add(m)
    m = col.models.by_name("Speech")

    def deck(name, **conf):
        did = col.decks.id(name)
        c = col.decks.add_config_returning_id(name)
        g = col.decks.get_config(c)
        g.update(conf)
        col.decks.update_config(g)
        d = col.decks.get(did)
        d["conf"] = c
        col.decks.update(d)
        n = col.new_note(m)
        n["DE"], n["ES"] = f"Hallo {name}", f"Hola {name}"
        col.add_note(n, did)
        n = col.new_note(m)
        n["DE"], n["ES"] = f"Zweite {name}", f"Segunda {name}"
        col.add_note(n, did)

    deck("Loud")
    deck("Quiet", autoplay=False)
    deck("OnlyBack", replayq=False)

    # "Support older Anki versions", under the kind of name desktop gives it.
    name = "collection-2026-11-05@14-10-21.colpkg"
    col.export_collection_package(str(WORK / name), include_media=True, legacy=True)
    col.reopen()
    steps("open;seed", reset=True)
    shutil.copy(WORK / name, docs() / name)
    d = steps(f"open;import:{name};integrity;check")
    r.need_ok(d, "legacy colpkg imported")
    r.check("replaces the collection", d["facts"]["notes"] == 6 and d["facts"]["cards"] == 6, d["facts"])
    r.check("result gives the new size", "6 notes, 6 cards" in detail(d, 1), detail(d, 1))

    d = steps("open;deck:Loud;card-text;reveal;spoken")
    r.need_ok(d, "studied a spoken card")
    q, a = detail(d, 2), detail(d, 3)
    r.check("no markup on the front", q == "Hallo Loud", q)
    r.check("no markup on the back", "anki:" not in a and a.count("Hallo Loud") == 1 and "Hola Loud" in a, a)
    r.check("front speaks, then the back repeats it and adds its own", detail(d) == "Hallo Loud+Hallo Loud+Hola Loud", detail(d))

    d = steps("open;deck:Loud;state;state;spoken;easy:1;spoken")
    r.check("refreshing the same card stays quiet", detail(d, 4) == "Hallo Loud", detail(d, 4))
    r.check("next card speaks", detail(d).endswith("Zweite Loud"), detail(d))

    d = steps("open;deck:Quiet;reveal;spoken")
    r.check("autoplay off stays quiet", detail(d) == "", detail(d))
    d = steps("open;deck:OnlyBack;reveal;spoken")
    r.check("back can skip the front's audio", detail(d) == "Hallo OnlyBack+Hola OnlyBack", detail(d))

    # Voice choice, from made-up lists of what a phone might have installed.
    for value, want, label in (
        ("de_DE|Apple_Anna_(Premium)|Hans/de-DE/1,Anna/de-DE/3", "Anna", "desktop's name finds the iOS voice"),
        ("de_DE|Apple_Anna_(Premium)|Anna (Premium)/de-DE/3,Hans/de-DE/1", "Anna (Premium)", "exact name wins"),
        ("de_DE|Microsoft_Katja|Hans/de-DE/1,Petra/de-DE/2,Amy/en-GB/3", "Petra", "unknown voice takes the best German one"),
        ("de_DE||Lena/de-AT/1,Amy/en-GB/3", "Lena", "falls back to the same language"),
        ("ja_JP||Amy/en-GB/3", "none", "no voice for the language"),
    ):
        got = detail(steps(f"open;voice:{value}"))
        r.check(label, got == want, got)

    # Text export, in the format of desktop's "Cards in Plain Text".
    col.export_card_csv(out_path=str(WORK / "All Decks.txt"), limit=DeckIdLimit(col.decks.id("Loud")), with_html=True)
    shutil.copy(WORK / "All Decks.txt", docs() / "All Decks.txt")
    d = steps("open;seed;idle:0", reset=True)
    before = d["facts"]["notes"]
    d = steps("open;import-text:All Decks.txt;integrity;check")
    r.need_ok(d, "text file imported")
    r.check("page reports the result", "new notes imported" in detail(d, 1), detail(d, 1)[:160])
    r.check("adds to the collection", d["facts"]["notes"] == before + 2, d["facts"])
    d = steps("open;import-text:All Decks.txt")
    r.check("importing again adds no copies", d["facts"]["notes"] == before + 2, d["facts"])

    (docs() / "notes.txt").write_text("Haus\tcasa\nBaum\tárbol\n", encoding="utf8")
    d = steps("open;import-text:notes.txt;last-note")
    r.need_ok(d, "plain two-column file imported")
    r.check("fields split by tab", detail(d).startswith("Baum\x1fárbol|"), detail(d)[:60])

    (docs() / "bad.pdf").write_bytes(b"%PDF")
    d = steps("open;import-text:bad.pdf")
    r.check("other file types refused", not d["steps"][-1]["ok"] and "can be imported" in detail(d), detail(d))
    col.close()
finally:
    server.kill()
r.finish()
