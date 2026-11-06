#!/usr/bin/env python3
"""Phase 1: .apkg and .colpkg files exported by desktop import correctly, including what follows.
Run with Anki's Python: build/anki/out/pyenv/bin/python tests/import_test.py"""
import shutil
from harness import Report, build, docs, steps
from peer import Desktop, PASSWORD, URL, USER, WORK, start_server
from anki.collection import ExportAnkiPackageOptions

ARGS = ("--sync-url", URL, "--sync-user", USER, "--sync-pass", PASSWORD)
build()
server = start_server()
r = Report()


def step(doc, name):
    return next(s for s in doc["steps"] if s["step"].startswith(name))


try:
    dk = Desktop()
    deck = dk.col.decks.id("Imported::Sub")
    for i in range(10):
        n = dk.col.new_note(dk.col.models.by_name("Basic"))
        n["Front"], n["Back"] = f"package note {i}" + ('<img src="pkg.png">' if i == 0 else ""), "back"
        dk.col.add_note(n, deck)
    dk.col.media.write_data("pkg.png", b"\x89PNG package")
    # Reviews, so scheduling has something to carry.
    dk.col.decks.select(deck)
    for _ in range(4):
        c = dk.col.sched.getCard()
        dk.col.sched.answerCard(c, 3)

    apkg, colpkg = WORK / "deck.apkg", WORK / "whole.colpkg"
    dk.col.export_anki_package(out_path=str(apkg), limit=None,
                               options=ExportAnkiPackageOptions(with_scheduling=True, with_deck_configs=True, with_media=True, legacy=False))
    dk.col.export_collection_package(str(colpkg), include_media=True, legacy=False)
    dk.col.reopen()

    # .apkg adds to what's there.
    steps("open;seed", reset=True)
    shutil.copy(apkg, docs() / "deck.apkg")
    d = steps("open;import:deck.apkg;check")
    r.need_ok(d, "apkg imported")
    r.check("apkg adds to existing notes", d["facts"]["notes"] == 14, d["facts"])
    r.check("apkg brought media", (docs() / "anki/media/pkg.png").read_bytes() == b"\x89PNG package")
    r.check("apkg kept scheduling", d["facts"]["revlog"] == 4, d["facts"])
    r.check("backup made before import", d["facts"]["backups"] >= 1, d["facts"])
    d = steps("open;import:deck.apkg")
    r.need_ok(d, "second import of same file")
    r.check("re-import adds no duplicates", d["facts"]["notes"] == 14, step(d, "import")["detail"])

    # Bad files fail cleanly and leave the collection alone.
    (docs() / "bad.apkg").write_bytes(b"this is not a zip file")
    d = steps("open;import:bad.apkg;integrity")
    r.check("corrupt apkg rejected", not step(d, "import")["ok"], str(step(d, "import")["detail"])[:90])
    r.check("collection intact after bad apkg", d["facts"]["notes"] == 14 and step(d, "integrity")["ok"], d["facts"])
    (docs() / "bad.colpkg").write_bytes(b"this is not a zip file")
    d = steps("open;import:bad.colpkg;integrity")
    r.check("corrupt colpkg rejected", not step(d, "import")["ok"], str(step(d, "import")["detail"])[:90])
    r.check("collection survives bad colpkg", d["facts"]["notes"] == 14 and step(d, "integrity")["ok"], d["facts"])
    (docs() / "notes.txt").write_text("hello")
    d = steps("open;import:notes.txt")
    r.check("other file types refused", not step(d, "import")["ok"], str(step(d, "import")["detail"])[:90])

    # .colpkg replaces everything, after a backup.
    before = d["facts"]["backups"]
    shutil.copy(colpkg, docs() / "whole.colpkg")
    d = steps("open;import:whole.colpkg;integrity;check")
    r.need_ok(d, "colpkg imported")
    r.check("colpkg replaced the collection", d["facts"]["notes"] == 10, d["facts"])
    r.check("colpkg kept reviews", d["facts"]["revlog"] == 4, d["facts"])
    r.check("backup made before replacing", d["facts"]["backups"] > before, d["facts"])

    # A replaced collection must not silently overwrite the server.
    dk.sync("upload")
    d = steps("open;login;sync:cancel", *ARGS)
    r.check("replaced collection asks before syncing", step(d, "sync")["detail"] in ("conflict", "confirmDownload", "confirmUpload"), step(d, "sync")["detail"])

    # Backups are real collection packages: one restores the earlier state.
    names = sorted(p.name for p in (docs() / "anki/backups").iterdir())
    shutil.copy(docs() / "anki/backups" / names[-1], docs() / "restore.colpkg")
    d = steps("open;import:restore.colpkg;integrity;check")
    r.need_ok(d, "newest backup restores")
    r.check("backup holds the pre-replace state", d["facts"]["notes"] == 14, d["facts"])
    dk.col.close()
finally:
    server.kill()
r.finish()
