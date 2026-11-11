#!/usr/bin/env python3
"""A scripted LSP client for kals: enough of the protocol to drive the server
from a test or by hand. Not part of the lit suite (Tests/ is frozen); run it
directly, see Analyzer/Dev/smoke.py."""
import json, os, queue, subprocess, threading, time


class Client:
    def __init__(self, exe, root, trace=False, env=None):
        self.p = subprocess.Popen([exe], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                  env=dict(os.environ, **(env or {})))
        self.root, self.trace, self.id = root, trace, 0
        self.q, self.notes, self.pending = queue.Queue(), [], {}
        threading.Thread(target=self._read, daemon=True).start()
        self.stderr = []
        threading.Thread(target=lambda: [self.stderr.append(l.decode(errors="replace")) for l in self.p.stderr], daemon=True).start()

    def _read(self):
        f = self.p.stdout
        while True:
            n = None
            while True:
                line = f.readline()
                if not line:
                    self.q.put(None)
                    return
                if line in (b"\r\n", b"\n"):
                    break
                if line.lower().startswith(b"content-length:"):
                    n = int(line.split(b":")[1])
            self.q.put(json.loads(f.read(n)))

    def send(self, obj):
        b = json.dumps(obj).encode()
        self.p.stdin.write(b"Content-Length: %d\r\n\r\n" % len(b) + b)
        self.p.stdin.flush()

    def notify(self, method, params):
        self.send({"jsonrpc": "2.0", "method": method, "params": params})

    def request(self, method, params, timeout=30):
        self.id += 1
        me = self.id
        self.send({"jsonrpc": "2.0", "id": me, "method": method, "params": params})
        end = time.time() + timeout
        while time.time() < end:
            try:
                m = self.q.get(timeout=0.1)
            except queue.Empty:
                continue
            if m is None:
                raise RuntimeError("server exited: " + "".join(self.stderr)[-2000:])
            if "method" in m:
                if "id" in m:  # a request from the server: acknowledge it
                    self.send({"jsonrpc": "2.0", "id": m["id"], "result": None})
                self.notes.append(m)
                continue
            if m.get("id") == me:
                if "error" in m:
                    return {"__error__": m["error"]}
                return m.get("result")
        raise TimeoutError(method)

    def pump(self, seconds):
        end = time.time() + seconds
        while time.time() < end:
            try:
                m = self.q.get(timeout=0.05)
            except queue.Empty:
                continue
            if m is None:
                return
            if "method" in m:
                if "id" in m:
                    self.send({"jsonrpc": "2.0", "id": m["id"], "result": None})
                self.notes.append(m)

    def uri(self, rel):
        return "file://" + os.path.join(self.root, rel)

    def start(self):
        r = self.request("initialize", {"processId": os.getpid(), "rootUri": "file://" + self.root,
                                        "capabilities": {"workspace": {"semanticTokens": {"refreshSupport": True}}}})
        self.notify("initialized", {})
        return r

    def open(self, rel, text=None):
        if text is None:
            text = open(os.path.join(self.root, rel)).read()
        self.notify("textDocument/didOpen", {"textDocument": {"uri": self.uri(rel), "languageId": "kairo", "version": 1, "text": text}})
        return text

    def change(self, rel, version, text):
        self.notify("textDocument/didChange", {"textDocument": {"uri": self.uri(rel), "version": version}, "contentChanges": [{"text": text}]})

    def at(self, rel, line, ch):
        return {"textDocument": {"uri": self.uri(rel)}, "position": {"line": line, "character": ch}}

    def diagnostics(self, rel):
        u, out = self.uri(rel), None
        for n in self.notes:
            if n["method"] == "textDocument/publishDiagnostics" and n["params"]["uri"] == u:
                out = n["params"]["diagnostics"]
        return out

    def stop(self):
        self.request("shutdown", None)
        self.notify("exit", None)
        try:
            return self.p.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.p.kill()
            return -9
