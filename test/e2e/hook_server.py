"""Receiver for URL hooks in the end-to-end suite.

Serves HTTP on 8080 and HTTPS on 8443 and appends one line per request to
LOG_FILE: "<scheme> <method> <path>", and one JSON object per request with its
path and headers to headers.log next to it. The first path segment picks the
reply:

  /ok/...        200
  /fail/...      403 (curl does not retry it)
  /error500/...  500 (curl --retry retries it)
  /redirect/...  302 to /ok/redirected/...
"""

import http.server
import json
import os
import ssl
import sys
import threading

LOG_FILE, CERT_FILE, KEY_FILE, READY_FILE = sys.argv[1:5]
HEADERS_FILE = os.path.join(os.path.dirname(LOG_FILE), "headers.log")
LOCK = threading.Lock()


class Handler(http.server.BaseHTTPRequestHandler):
    def handle_any(self):
        scheme = "https" if self.server.server_port == 8443 else "http"
        with LOCK:
            with open(LOG_FILE, "a", encoding="utf-8") as log:
                log.write(f"{scheme} {self.command} {self.path}\n")
            with open(HEADERS_FILE, "a", encoding="utf-8") as log:
                log.write(json.dumps({"path": self.path, "headers": dict(self.headers.items())}) + "\n")

        kind = self.path.split("/")[1] if self.path.count("/") >= 1 else ""
        if kind == "fail":
            self.send_response(403)
        elif kind == "error500":
            self.send_response(500)
        elif kind == "redirect":
            self.send_response(302)
            self.send_header("Location", "/ok/redirected" + self.path[len("/redirect"):])
        else:
            self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(b"ok")

    do_GET = do_POST = do_PUT = do_HEAD = handle_any

    def log_message(self, *args):
        pass


def serve(server):
    server.serve_forever()


def main():
    plain = http.server.ThreadingHTTPServer(("0.0.0.0", 8080), Handler)
    secure = http.server.ThreadingHTTPServer(("0.0.0.0", 8443), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(CERT_FILE, KEY_FILE)
    secure.socket = context.wrap_socket(secure.socket, server_side=True)

    for server in (plain, secure):
        threading.Thread(target=serve, args=(server,), daemon=True).start()

    with open(READY_FILE, "w", encoding="utf-8") as ready:
        ready.write("ready\n")
    threading.Event().wait()


if __name__ == "__main__":
    main()
