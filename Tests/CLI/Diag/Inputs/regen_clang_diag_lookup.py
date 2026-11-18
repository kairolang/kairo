"""Regenerates the Clang diagnostic tables from the checked-in manifest and
compares them with the checked-in outputs. The group list the generator reads
from the compiler's identity tool is the manifest's active groups.
Usage: regen_clang_diag_lookup.py <repo root>. Prints one line per output."""
import subprocess, sys, tempfile, tomllib
from pathlib import Path

root = Path(sys.argv[1])
manifest = root / "Compiler/Diagnostic/TableGen/ClangDiagCodes.toml"
with manifest.open("rb") as f:
    groups = [n for n, e in tomllib.load(f)["groups"].items() if not e.get("removed")]
with tempfile.TemporaryDirectory() as d:
    d = Path(d)
    (d / "groups.txt").write_text("\n".join(groups) + "\n")
    (d / "m.toml").write_bytes(manifest.read_bytes())
    subprocess.run([sys.executable, str(root / "Scripts/gen_clang_diag_table.py"),
                    "--input", str(d / "groups.txt"), "--manifest", str(d / "m.toml"),
                    "--output", str(d / "Clang.diag.toml"), "--lookup-output", str(d / "Lookup.k")],
                   check=True, stdout=subprocess.DEVNULL)
    for name, got, want in (
        ("lookup", d / "Lookup.k", root / "Compiler/Diagnostic/ClangDiagLookup.k"),
        ("diag-table", d / "Clang.diag.toml", root / "Compiler/Diagnostic/TableGen/Clang.diag.toml"),
        ("manifest", d / "m.toml", manifest),
    ):
        print(name, "identical" if got.read_bytes() == want.read_bytes() else "DIFFERS")
