"""HTTP twin of the suites' fake `curl`, for running them against the native bridge.

    python3 tests/capture_server.py <port> <ctrl-dir>

Port 0 picks a free port; once listening, the server writes the port it got to <ctrl-dir>/port.

Per request it reads the case's settings from <ctrl-dir>, which the suite rewrites before every
run, and records exactly what the fake curl would have:
  ctrl/cap    capture directory: the body goes to <cap>/body.N, the first free N
  ctrl/code   HTTP status to answer (default 200); 000 closes the connection unanswered,
              which is how a transport failure looks to the caller
  ctrl/calls  if present, a file that gets one "POST <path>" line per request
"""
import http.server
import socketserver
import os
import sys

PORT, CTRL = int(sys.argv[1]), sys.argv[2]


def setting(name, default=""):
    try:
        with open(os.path.join(CTRL, name)) as f:
            return f.read().strip() or default
    except OSError:
        return default


class Server(http.server.ThreadingHTTPServer):
    # HTTPServer looks up its own host name on bind, which can stall for seconds on macOS runners.
    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("content-length") or 0))
        cap = setting("cap")
        if cap:
            n = 0
            while os.path.exists(os.path.join(cap, f"body.{n}")):
                n += 1
            with open(os.path.join(cap, f"body.{n}"), "wb") as f:
                f.write(body)
            with open(os.path.join(cap, f"headers.{n}"), "w") as f:
                for k, v in self.headers.items():
                    f.write(f"{k.lower()}: {v}\n")
        calls = setting("calls")
        if calls:
            with open(calls, "a") as f:
                f.write(f"POST {self.path}\n")
        code = setting("code", "200")
        if code == "000":
            self.close_connection = True
            self.connection.close()
            return
        self.send_response(int(code))
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"{}")

    do_GET = do_POST

    def log_message(self, *args):
        pass


server = Server(("127.0.0.1", PORT), Handler)
with open(os.path.join(CTRL, "port.tmp"), "w") as f:
    f.write(str(server.server_address[1]))
os.replace(os.path.join(CTRL, "port.tmp"), os.path.join(CTRL, "port"))
server.serve_forever()
