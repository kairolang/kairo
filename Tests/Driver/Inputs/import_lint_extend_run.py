"""Runs import_lint.py --fix twice, each over a fresh dump, over a copy of the fixture outside Tests/
(the tool refuses to edit Tests/) and prints what each run said and the fixed
main.k. Usage: import_lint_extend_run.py <kairo> <import_lint.py> <fixture>."""
import shutil, subprocess, sys, tempfile
from pathlib import Path

kairo, lint, fixture = sys.argv[1:4]
with tempfile.TemporaryDirectory() as d:
    work = Path(d) / "tree"
    shutil.copytree(fixture, work)
    dump = Path(d) / "dump.json"
    for tag in ("FIRST", "SECOND"):
        subprocess.run([kairo, "--type-check-only", "-I", ".", f"--dump-import-uses={dump}", "main.k"],
                       cwd=work, check=True)
        r = subprocess.run([sys.executable, lint, str(work), "--dump", str(dump), "--fix", "-v"],
                           capture_output=True, text=True)
        print(tag, r.returncode)
        for line in (r.stdout + r.stderr).splitlines():
            print(tag, line.replace(str(work), "<tree>"))
    print("MAIN-BEGIN")
    print((work / "main.k").read_text())
