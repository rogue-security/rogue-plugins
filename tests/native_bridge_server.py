"""
Mock of GET /api/v1/hooks/download and the presigned download it points to, for the
native bridge install tests. Appends "<path> key=<x-rogue-api-key>" per request to
<dir>/requests and serves <dir>/blob as the binary. POSTed hook events get {}.

Usage: python3 native_bridge_server.py <port> <dir>
"""
import http.server
import sys

port, srv = int(sys.argv[1]), sys.argv[2]


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with open(f"{srv}/requests", "a") as f:
            f.write(f"{self.path} key={self.headers.get('x-rogue-api-key')}\n")
        if self.path.startswith("/api/v1/hooks/download?"):
            url = f"http://127.0.0.1:{port}/blob?X-Amz-Signature=abc&X-Amz-Expires=300"
            body = f'{{"url":"{url}"}}'.encode()
        else:
            with open(f"{srv}/blob", "rb") as f:
                body = f.read()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    # Hook events posted by a script bridge get the empty allow answer.
    def do_POST(self):
        self.rfile.read(int(self.headers.get("content-length") or 0))
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"{}")

    def log_message(self, *_):
        pass


http.server.HTTPServer(("127.0.0.1", port), Handler).serve_forever()
