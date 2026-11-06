"""A desktop Anki client and a local sync server, for testing against the iOS app."""
import os, random, shutil, subprocess, sys, time, urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PY = ROOT / "build/anki/out/pyenv/bin/python"
PYLIB = str(ROOT / "build/anki/out/pylib")
WORK = ROOT / "build/test"
sys.path.insert(0, PYLIB)

ENV = dict(l.split("=", 1) for l in (ROOT / "tests/sync-test.env").read_text().split() if "=" in l)
USER, PASSWORD, PORT = ENV["SYNC_TEST_USER"], ENV["SYNC_TEST_PASS"], ENV["SYNC_TEST_PORT"]
URL = f"http://127.0.0.1:{PORT}/"

from anki.collection import Collection  # noqa: E402


def start_server(host="127.0.0.1", fresh=True):
    if fresh:
        shutil.rmtree(WORK, ignore_errors=True)
    WORK.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, SYNC_USER1=f"{USER}:{PASSWORD}", SYNC_BASE=str(WORK / "server"), SYNC_HOST=host,
               SYNC_PORT=PORT, PYTHONPATH=PYLIB)
    log = open(WORK / "server.log", "a")
    p = subprocess.Popen([str(PY), "-m", "anki.syncserver"], env=env, stdout=log, stderr=log)
    for _ in range(100):
        try:
            urllib.request.urlopen(URL + "health", timeout=1)
            return p
        except OSError:
            time.sleep(0.1)
    p.kill()
    sys.exit("sync server did not start: " + (WORK / "server.log").read_text()[-500:])


def fill(col, notes):
    """Fills a collection to look long-used: many decks, mostly mature cards, and history."""
    from anki.collection import AddNoteRequest
    decks = [col.decks.id(f"Subject {i // 5}::Topic {i}") for i in range(50)]
    nt = col.models.by_name("Basic")
    reqs = []
    for i in range(notes):
        n = col.new_note(nt)
        n["Front"], n["Back"] = f"bulk question {i} " + "lorem ipsum " * 8, f"answer {i} " + "dolor sit " * 20
        reqs.append(AddNoteRequest(note=n, deck_id=decks[i % 50]))
        if len(reqs) == 5000:
            col.add_notes(reqs)
            reqs = []
    if reqs:
        col.add_notes(reqs)
    now = int(time.time())
    today = col.sched.today
    ids = col.db.list("select id from cards")
    col.db.executemany("update cards set type=2, queue=2, ivl=?, due=?, reps=10, factor=2500 where id=?",
                       [(random.randint(5, 300), today + random.randint(-3, 200), c) for c in ids[: len(ids) * 9 // 10]])
    rev = [(now * 1000 - 1000 * j - c % 1000000, c, -1, 3, 30, 15, 2500, 8000, 1) for j, c in enumerate(ids[: len(ids) * 9 // 10] * 5)]
    col.db.executemany("insert or ignore into revlog values (?,?,?,?,?,?,?,?,?)", rev)
    col.mod_schema(check=False)


class Desktop:
    def __init__(self, name="desktop"):
        d = WORK / name
        d.mkdir(parents=True, exist_ok=True)
        self.col = Collection(str(d / "collection.anki2"))
        self.auth = self.col.sync_login(USER, PASSWORD, URL)
        self.auth.endpoint = URL

    def add(self, front, back="back"):
        n = self.col.new_note(self.col.models.by_name("Basic"))
        n["Front"], n["Back"] = front, back
        self.col.add_note(n, 1)
        return n

    def schema_change(self):
        m = self.col.models.by_name("Basic")
        self.col.models.add_field(m, self.col.models.new_field(f"Extra{self.col.db.scalar('select count() from notes')}"))
        self.col.models.update_dict(m)

    def sync(self, full=None):
        """Normal sync. `full` is 'upload' or 'download' if a full sync is expected."""
        out = self.col.sync_collection(self.auth, True)
        needed = out.required != out.NO_CHANGES
        if needed:
            if full is None:
                raise Exception(f"unexpected full sync: {out.required}")
            self.col.close_for_full_sync()
            self.col.full_upload_or_download(auth=self.auth, server_usn=out.server_media_usn, upload=full == "upload")
            self.col.reopen(after_full_sync=True)
        for _ in range(300):
            if not self.col._backend.media_sync_status().active:
                break
            time.sleep(0.1)
        return needed

    def count(self, what):
        return self.col.db.scalar(f"select count() from {what}")

    def media(self):
        return sorted(os.listdir(self.col.media.dir()))
