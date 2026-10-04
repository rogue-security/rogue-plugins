"""
Tiny HTTP mock that records the inbound headers (so the smoke test can assert
on x-rogue-event etc.) and returns whatever bytes the env var MOCK_RESPONSE
contains. Sends MOCK_STATUS as the HTTP status (default 200). MOCK_DELAY (seconds,
default 0) holds the response back so a bridge's timeout path can be exercised.

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
        # Record headers + body so the test can inspect them.
        with open(HEADERS_PATH, "w") as f:
            json.dump({
                "headers": {k.lower(): v for k, v in self.headers.items()},
                "body": body_in.decode("utf-8", errors="replace"),
                "path": self.path,
            }, f)
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
