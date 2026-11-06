"""
Tiny HTTP mock that records the inbound headers (so the smoke test can assert
on x-rogue-event etc.) and returns whatever bytes the env var MOCK_RESPONSE
contains. Sends MOCK_STATUS as the HTTP status (default 200). MOCK_DELAY (seconds,
default 0) holds the response back so a bridge's timeout path can be exercised.
MOCK_CALLS, if set, is a file that gets one "<path> <body>" line per request.
MOCK_ONLY_PATH, when set, limits all of that to requests for that path: any other
request is answered {} at once and appended to <headers-file>.other as one
"<METHOD> <path> <body>" line, so a detached heartbeat cannot overwrite the
recorded hook request.

Usage:
    MOCK_RESPONSE='{"hookSpecificOutput":{"permissionDecision":"deny"}}' \
        python3 mock_server.py 9876 /tmp/mock-headers.json
"""
import http.server
import json
import os
import sys
import time


HEADERS_PATH = sys.argv[2] if len(sys.argv) > 2 else "/tmp/rogue-mock-headers.json"


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body_in = self.rfile.read(length)
        only = os.environ.get("MOCK_ONLY_PATH")
        if only and self.path != only:
            with open(HEADERS_PATH + ".other", "a") as f:
                f.write(f"{self.command} {self.path} {body_in.decode('utf-8', errors='replace')}\n")
            self.send_response(200)
            self.send_header("Content-Length", "2")
            self.end_headers()
            self.wfile.write(b"{}")
            return
        # Record headers + body so the test can inspect them.
        with open(HEADERS_PATH, "w") as f:
            json.dump({
                "headers": {k.lower(): v for k, v in self.headers.items()},
                "body": body_in.decode("utf-8", errors="replace"),
                "path": self.path,
            }, f)
        calls = os.environ.get("MOCK_CALLS")
        if calls:
            with open(calls, "a") as f:
                f.write(f"{self.path} {body_in.decode('utf-8', errors='replace')}\n")
        time.sleep(float(os.environ.get("MOCK_DELAY", "0")))
        status = int(os.environ.get("MOCK_STATUS", "200"))
        body = os.environ.get("MOCK_RESPONSE", "{}").encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):  # silence default access log
        pass


if __name__ == "__main__":
    port = int(sys.argv[1])
    http.server.HTTPServer(("127.0.0.1", port), Handler).serve_forever()
