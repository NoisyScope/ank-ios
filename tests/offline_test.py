#!/usr/bin/env python3
"""Studying without a connection, and that the work arrives once there is one."""
import socket, threading, time
from harness import Report, build, steps
from peer import Desktop, PASSWORD, PORT, URL, USER, start_server

ARGS = ("--sync-url", URL, "--sync-user", USER, "--sync-pass", PASSWORD)
build()
server = start_server()
r = Report()
QUICK = 3000  # ms to the first card. A sync stuck on the network takes 30 seconds.


def detail(doc, i=-1):
    return doc["steps"][i]["detail"]


class Dead:
    """Accepts connections and never answers, like a weak signal or a captive network."""
    def __init__(self):
        self.s = socket.socket()
        self.s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.s.bind(("127.0.0.1", int(PORT)))
        self.s.listen(20)
        self.held = []
        threading.Thread(target=self.run, daemon=True).start()

    def run(self):
        try:
            while True:
                self.held.append(self.s.accept()[0])
        except OSError:
            pass

    def close(self):
        for c in self.held:
            c.close()
        self.s.close()


def stop():
    server.kill()
    server.wait()


def start_check(label, d, i=-1):
    got = dict(p.split("=") for p in detail(d, i).split())
    r.check(f"{label}: card appears straight away", 0 <= int(got["shown"]) < QUICK, detail(d, i))
    r.check(f"{label}: study isn't blocked", got["blocked"] == "False".lower(), detail(d, i))


dead = None
try:
    dk = Desktop()
    for i in range(30):
        dk.add(f"offline note {i}")
    r.check("desktop full upload", dk.sync("upload"))
    d = steps("open;login;sync:download", *ARGS, reset=True)
    r.need_ok(d, "app downloaded")

    # Connected as far as the phone can tell, but nothing answers.
    stop()
    dead = Dead()
    d = steps("start;review:2;revlog")
    start_check("dead network", d, 0)
    r.need_ok(d, "studied on a dead network")
    r.check("answers are recorded", detail(d) == "2", detail(d))
    d = steps("open;revlog;integrity")
    r.check("answers survive a restart", detail(d, 1) == "2", detail(d, 1))
    dead.close()
    dead = None

    # Nothing there at all.
    d = steps("start;review:1;revlog;manual-sync")
    start_check("no server", d, 0)
    r.check("studying works", detail(d, 2) == "3", detail(d, 2))
    r.check("asking to sync explains", "saved on this device" in detail(d), detail(d)[:90])

    # The device reports no network: nothing is tried, and study goes on.
    d = steps("open;idle:3;restore-login;online:off;review:1;auto-sync;manual-sync;revlog")
    r.need_ok(d, "studied in airplane mode")
    r.check("automatic sync stays quiet", detail(d, -3).startswith("error=|"), detail(d, -3))
    r.check("asking to sync explains without waiting", d["steps"][-2]["ms"] < 500 and "saved on this device" in detail(d, -2), d["steps"][-2])
    r.check("all reviews are here", detail(d) == "4", detail(d))

    # Connection returns: the work goes without a tap, in normal sync.
    server = start_server(fresh=False)
    dk.sync()
    r.check("desktop has none of it yet", dk.count("revlog") == 0, dk.count("revlog"))
    d = steps("open;idle:3;restore-login;online:off;online:on;idle:3")
    r.need_ok(d, "connection came back")
    r.check("no full sync needed", not dk.sync())
    r.check("all offline reviews arrive by themselves", dk.count("revlog") == 4, dk.count("revlog"))

    # The network stays up the whole time but AnkiWeb comes back later: it keeps trying.
    stop()
    dead = Dead()

    def recover():
        global server, dead
        time.sleep(6)
        dead.close()
        dead = None
        server = start_server(fresh=False)

    t = threading.Thread(target=recover)
    t.start()
    d = steps("open;idle:3;restore-login;review:1;auto-sync;idle:30;revlog", timeout=90)
    t.join()
    r.need_ok(d, "studied until the server returned")
    dk.sync()
    r.check("retries until it gets through", dk.count("revlog") == 5, dk.count("revlog"))

    # With a working connection the card still comes first.
    d = steps("start")
    start_check("online", d, 0)
    d = steps("open;integrity;check")
    r.need_ok(d, "database intact")
    dk.col.close()
finally:
    if dead:
        dead.close()
    server.kill()
r.finish()
