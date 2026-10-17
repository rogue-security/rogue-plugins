"""
Mock of GET /api/v1/hooks/binary and the presigned download it points to, for the
hook binary install tests. Appends "<path> key=<x-rogue-api-key>" per request to
<dir>/requests and serves <dir>/blob as the binary.

Usage: python3 hook_binary_server.py <port> <dir>
"""
import http.server
import sys

port, srv = int(sys.argv[1]), sys.argv[2]


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with open(f"{srv}/requests", "a") as f:
            f.write(f"{self.path} key={self.headers.get('x-rogue-api-key')}\n")
        if self.path.startswith("/api/v1/hooks/binary?"):
            url = f"http://127.0.0.1:{port}/blob?X-Amz-Signature=abc&X-Amz-Expires=300"
            body = f'{{"url":"{url}"}}'.encode()
        else:
            with open(f"{srv}/blob", "rb") as f:
                body = f.read()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


http.server.HTTPServer(("127.0.0.1", port), Handler).serve_forever()
