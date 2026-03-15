#!/usr/bin/env python3
"""Lightweight HTTP endpoint exposing last activity timestamp on port 8080."""
import json
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
TS_FILE = "/var/lib/activity/last_activity"

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/activity":
            self.send_response(404)
            self.end_headers()
            return
        try:
            with open(TS_FILE, "r") as f:
                ts = int(f.read().strip())
        except Exception:
            ts = int(time.time())
        payload = {"last_activity_timestamp": ts}
        body = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        return

if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", 8080), Handler)
    server.serve_forever()
