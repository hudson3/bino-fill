#!/usr/bin/env python3
"""Bino's local decision server.

Listens on 127.0.0.1 only, on a port the system picks, and requires a token that it
writes to a file only you can read. It is sent field labels and names, never values.
It shuts itself down after a stretch of inactivity.
"""
import argparse
import json
import os
import secrets
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from engine import DEFAULT_MODEL, MODELS, Engine  # noqa: E402

STATE = dict(engine=None, token="", last_used=time.time(), lock=threading.Lock())


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _send(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorized(self):
        return secrets.compare_digest(self.headers.get("Authorization", ""), "Bearer " + STATE["token"])

    def do_GET(self):
        if not self._authorized():
            return self._send(401, dict(error="unauthorized"))
        if self.path == "/health":
            return self._send(200, dict(ok=True, model=STATE["engine"].model))
        self._send(404, dict(error="not found"))

    def do_POST(self):
        if not self._authorized():
            return self._send(401, dict(error="unauthorized"))
        if self.path != "/choose":
            return self._send(404, dict(error="not found"))
        try:
            length = int(self.headers.get("Content-Length", "0"))
            request = json.loads(self.rfile.read(length))
            items = request["items"]
            results = []
            with STATE["lock"]:
                STATE["last_used"] = time.time()
                for item in items:
                    started = time.time()
                    result = STATE["engine"].choose(item["state"], item["question"], item["options"])
                    result["ms"] = round((time.time() - started) * 1000)
                    results.append(result)
                STATE["last_used"] = time.time()
            self._send(200, dict(results=results))
        except (KeyError, ValueError, TypeError) as error:
            self._send(400, dict(error=str(error)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default=DEFAULT_MODEL, choices=sorted(MODELS))
    ap.add_argument("--state-file", required=True, help="where to write the port and token")
    ap.add_argument("--idle-minutes", type=float, default=20)
    args = ap.parse_args()

    # Leave the session of whatever started us (a terminal, or an agent's command runner)
    # so the model stays loaded after that command ends.
    try:
        os.setsid()
    except OSError:
        pass

    STATE["engine"] = Engine(args.model)
    STATE["token"] = secrets.token_urlsafe(32)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)

    state = dict(port=server.server_address[1], token=STATE["token"], pid=os.getpid(), model=args.model)
    tmp = args.state_file + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(state, f)
    os.replace(tmp, args.state_file)

    def watchdog():
        while True:
            time.sleep(30)
            if time.time() - STATE["last_used"] > args.idle_minutes * 60:
                try:
                    current = json.load(open(args.state_file))
                    if current.get("pid") == os.getpid():
                        os.remove(args.state_file)
                except (OSError, ValueError):
                    pass
                os._exit(0)

    threading.Thread(target=watchdog, daemon=True).start()
    server.serve_forever()


if __name__ == "__main__":
    main()
