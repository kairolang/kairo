"""Drives `kals --worker --syntax-server` (LanguageServer.md section 11, 2a)
directly, without the server: N buffers (every 7th broken), every 25th
answer compared with the per-process syntax pass, time per pass, resident
size, and supersession. Usage: syntax_server_bench.py <kals> [N]"""
import json, os, subprocess, sys, time, statistics, tempfile
kals, n = os.path.abspath(sys.argv[1]), int(sys.argv[2]) if len(sys.argv) > 2 else 300
d = tempfile.mkdtemp(prefix="kals-syn-")
f = os.path.join(d, "buf.k")
base = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "smoke.py")).read().split("SHAPES = '''")[1].split("'''")[0]
open(f, "w").write(base)
p = subprocess.Popen([kals, "--worker", "--syntax-server", "--"], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
def rss():
    for l in open(f"/proc/{p.pid}/status"):
        if l.startswith("VmRSS"):
            return int(l.split()[1]) // 1024
def send(obj):
    b = json.dumps(obj).encode()
    p.stdin.write(b"Content-Length: %d\r\n\r\n" % len(b) + b); p.stdin.flush()
def recv():
    n = None
    while True:
        l = p.stdout.readline()
        if l in (b"\r\n", b""):
            break
        if l.lower().startswith(b"content-length"):
            n = int(l.split(b":")[1])
    return json.loads(p.stdout.read(n))
def per_process(text):
    tmp = os.path.join(d, "tmp.k"); out = os.path.join(d, "out.json")
    open(tmp, "w").write(text)
    t = time.time()
    subprocess.run([kals, "--worker", out, "--syntax-only", f, "--overlay", f, tmp, "--", f], check=False)
    return json.load(open(out)), time.time() - t
times, ptimes, mism = [], [], 0
r0 = None
for i in range(n):
    text = base + "\npub fn extra%d() -> i32 { return %d }\n" % (i, i)
    if i % 7 == 3:
        text += "\npub fn broken( {\n"
    t = time.time(); send({"id": i, "file": f, "text": text}); a = recv(); times.append(time.time() - t)
    if i == 1:
        r0 = rss()
    if i % 25 == 0:
        b, pt = per_process(text); ptimes.append(pt)
        a2 = {k: v for k, v in a.items() if k != "id"}
        if a2 != b:
            mism += 1
            print("MISMATCH", i, json.dumps(a2)[:300], json.dumps(b)[:300])
    if a.get("id") != i or not a.get("ok"):
        print("BAD", i, a); mism += 1
# supersede: two buffers of the same file back to back
send({"id": 9001, "file": f, "text": base}); send({"id": 9002, "file": f, "text": base + "\n"})
got = [recv() for _ in range(2)]
r1 = rss()
p.stdin.close(); rc = p.wait(timeout=10)
q = lambda v: "median %.1f ms (%.1f..%.1f)" % (statistics.median(v) * 1000, min(v) * 1000, max(v) * 1000)
print("server passes:", len(times), q(times))
print("per-process passes:", len(ptimes), q(ptimes))
print("rss MB after 2 passes: %s, after %d: %s" % (r0, n, r1))
print("mismatches:", mism, "exit:", rc)
print("superseded:", [(g.get("id"), g.get("superseded", False)) for g in got])
