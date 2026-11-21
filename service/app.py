import json
import os
import signal
import socket
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CONFIG_DIR = os.environ.get("CONFIG_DIR", "/etc/app-config")


def setting(name):
    """Prefer the mounted ConfigMap file (kubelet updates it without a restart),
    fall back to the environment variable."""
    try:
        with open(os.path.join(CONFIG_DIR, name)) as f:
            return f.read().strip()
    except OSError:
        return os.environ.get(name, "")


class Handler(BaseHTTPRequestHandler):
    def _send(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/":
            # Read on every request so ConfigMap/env changes are reflected.
            self._send(200, {
                "app": setting("APP_NAME"),
                "version": setting("VERSION"),
                "pod": socket.gethostname(),
            })
        elif path == "/healthz":
            self._send(200, {"status": "ok"})
        else:
            self._send(404, {"error": "not found"})

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))


def main():
    port = int(os.environ.get("PORT", "8080"))
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)

    def stop(signum, frame):
        # shutdown() must run in another thread; calling it here would deadlock.
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    print("listening on :%d" % port, flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
