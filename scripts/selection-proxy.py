#!/usr/bin/env python3
"""Loopback proxy for UI tests of pending states (SelectionPendingTests, PipelineExecutionUITests, PushAccountUITests,
PushDeepLinkUITests, AccountSwitchUITests): forwards to a local
backend, but the test can delay or fail the selection preview, the mandate save and the pipeline actions, so the pending,
failed and cancelled states can be seen and asserted.

  selection-proxy.py <listen port> <backend port>

  POST /__control {"preview": {"delay": 5, "status": 200}, "save": {...}}   replaces the rules and clears the log
                  (rules: preview, save, exec-start, exec-stop, exec-continue, exec-retry, push-register, push-revoke,
                  push-prefs-get, push-prefs-set, logout, live, live-head, favorite)
  GET  /__log     [{"rule": "preview", "status": 200, "forwarded": true}, ...] answered slow requests, oldest first

A forced status other than 200 is answered without asking the backend, so nothing is stored.
"""
import http.client
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

listen, backend = int(sys.argv[1]), int(sys.argv[2])
RULES = {("POST", "/v1/project-selection/preview"): "preview", ("PUT", "/v1/settings/brain-mandate"): "save",
         ("POST", "/v1/push/devices"): "push-register", ("GET", "/v1/me/push-prefs"): "push-prefs-get",
         ("POST", "/v1/me/push-prefs"): "push-prefs-set", ("POST", "/v1/auth/logout"): "logout", ("GET", "/v1/sync/wait"): "live", ("GET", "/v1/sync/head"): "live-head"}
PIPELINE = (("/execution", "exec-start"), ("/execution/stop", "exec-stop"), ("/execution/continue", "exec-continue"), ("/retry", "exec-retry"))
rules, log = {}, []


def rule_name(method, path):
    if method == "DELETE" and path.startswith("/v1/push/devices/"):
        return "push-revoke"
    if method == "POST" and "/pipeline/" in path:
        return next((name for end, name in PIPELINE if path.endswith(end)), None)
    if method == "PUT" and path.startswith("/v1/me/favorites/"):
        return "favorite"
    return RULES.get((method, path))


class Proxy(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def reply(self, status, headers, data):
        self.send_response(status)
        for k, v in headers:
            if k.lower() not in ("connection", "content-length", "transfer-encoding", "date", "server"):
                self.send_header(k, v)
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def forward(self):
        body = self.rfile.read(int(self.headers.get("content-length") or 0))
        path = self.path.split("?")[0]
        if path == "/__control":
            rules.clear()
            rules.update(json.loads(body))
            log.clear()
            return self.reply(200, [], b"{}")
        if path == "/__log":
            return self.reply(200, [("content-type", "application/json")], json.dumps(log).encode())
        name = rule_name(self.command, path)
        rule = rules.get(name, {}) if name else {}
        time.sleep(rule.get("delay", 0))
        status = rule.get("status", 200)
        if status != 200:
            headers, data, forwarded = [("content-type", "application/json")], b'{"error":true,"reason":"forced"}', False
        else:
            conn = http.client.HTTPConnection("127.0.0.1", backend, timeout=90)
            sent = {k: v for k, v in self.headers.items() if k.lower() not in ("connection", "content-length")}
            conn.request(self.command, self.path, body=body or None, headers=sent)
            res = conn.getresponse()
            status, headers, data, forwarded = res.status, res.getheaders(), res.read(), True
            conn.close()
        if name:
            entry = {"rule": name, "status": status, "forwarded": forwarded}
            log.append(entry)
            print(entry, flush=True)
        self.reply(status, headers, data)

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = forward

    def log_message(self, *args):
        pass


class Server(ThreadingHTTPServer):
    def handle_error(self, request, client_address):  # the app drops cancelled requests and closes on quit
        if not isinstance(sys.exc_info()[1], (BrokenPipeError, ConnectionResetError)):
            super().handle_error(request, client_address)


Server(("127.0.0.1", listen), Proxy).serve_forever()
