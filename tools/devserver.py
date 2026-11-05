"""Kindle debug relay.

The Kindle runs devagent/agent.sh, which long-polls this server over Wi-Fi for shell
commands, runs them, and posts the output (and any uploaded files) back.

Kindle-facing endpoints (need ?t=TOKEN):
  GET  /poll            -> "ID\\nCOMMAND" or empty after ~20s
  POST /result?id=ID    -> body is command output
  POST /file?name=NAME  -> body saved to tools/inbox/NAME
Local-only control endpoints (127.0.0.1 only), used by kctl.py:
  POST /enqueue         -> body is command, returns ID
  GET  /wait?id=ID&timeout=S -> command output (blocks)
  GET  /status          -> last time the Kindle polled
"""
import os, threading, time, itertools, json
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

HERE = os.path.dirname(os.path.abspath(__file__))
INBOX = os.path.join(HERE, "inbox")
ROOT = os.path.dirname(HERE)                      # the kindle-mod folder
ALLOWED_DL = {"devagent", "deskclock", "documents", "deskdash.koplugin"}  # only these folders can be pulled by the Kindle
TOKEN = open(os.path.join(HERE, ".devtoken")).read().strip()
PORT = int(os.environ.get("KINDLE_DEV_PORT", "8765"))
os.makedirs(INBOX, exist_ok=True)

lock = threading.Condition()
queue = []            # [(id, cmd)]
results = {}          # id -> bytes
ids = itertools.count(1)
last_poll = {"t": 0.0, "addr": None}


class H(BaseHTTPRequestHandler):
    def log_message(self, format, *args):  # quiet
        pass

    def _reply(self, code=200, body=b"", ctype="text/plain; charset=utf-8"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _q(self):
        u = urlparse(self.path)
        return u.path, {k: v[0] for k, v in parse_qs(u.query).items()}

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def _local(self):
        return self.client_address[0] == "127.0.0.1"

    def do_GET(self):
        path, q = self._q()
        if path == "/poll":
            if q.get("t") != TOKEN:
                return self._reply(403)
            with lock:
                last_poll["t"] = time.time()
                last_poll["addr"] = self.client_address[0]
                lock.wait_for(lambda: queue, timeout=20)
                if not queue:
                    return self._reply(200, b"")
                cid, cmd = queue.pop(0)
            return self._reply(200, f"{cid}\n{cmd}".encode())
        if path == "/dl":
            if q.get("t") != TOKEN:
                return self._reply(403)
            rel = os.path.normpath(q.get("name", "")).replace("\\", "/")
            if rel.split("/")[0] not in ALLOWED_DL or ".." in rel.split("/"):
                return self._reply(403)
            full = os.path.join(ROOT, rel)
            if not os.path.isfile(full):
                return self._reply(404)
            with open(full, "rb") as f:
                return self._reply(200, f.read(), "application/octet-stream")
        if path == "/wait" and self._local():
            cid = int(q["id"])
            deadline = time.time() + float(q.get("timeout", "60"))
            with lock:
                while cid not in results and time.time() < deadline:
                    lock.wait(timeout=max(0.1, deadline - time.time()))
                out = results.pop(cid, None)
            if out is None:
                return self._reply(504, b"timeout waiting for Kindle")
            return self._reply(200, out)
        if path == "/status" and self._local():
            age = time.time() - last_poll["t"] if last_poll["t"] else None
            return self._reply(200, json.dumps({"last_poll_age_s": age, "kindle": last_poll["addr"], "queued": len(queue)}).encode())
        self._reply(404)

    def do_POST(self):
        path, q = self._q()
        body = self._body()
        if path == "/enqueue" and self._local():
            with lock:
                cid = next(ids)
                queue.append((cid, body.decode()))
                lock.notify_all()
            return self._reply(200, str(cid).encode())
        if q.get("t") != TOKEN:
            return self._reply(403)
        if path == "/result":
            with lock:
                results[int(q["id"])] = body
                lock.notify_all()
            return self._reply(200, b"ok")
        if path == "/file":
            name = os.path.basename(q.get("name", "upload.bin"))
            with open(os.path.join(INBOX, name), "wb") as f:
                f.write(body)
            return self._reply(200, b"ok")
        self._reply(404)


if __name__ == "__main__":
    print(f"Kindle dev relay on 0.0.0.0:{PORT}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
