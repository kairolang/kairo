"""Lays out the glibc recipe's compiler-rt dir for every arch and asks clang to find it.

    python3 glibc_rt_dir.py <clang> <scratch dir>

The dir comes from the real recipe (Scripts/ship_sysroot_inputs.py, FAMILIES["glibc"]
resource_layout), so a root ksys assembles from it is one a clang handed the same
target and -resource-dir=<root>/compiler-rt finds. Each arch is tried with the
recipe's triple and with the vendor-unknown spelling kairo reports. Prints one line
per arch and spelling: "ok" or "MISSING <dir clang looked in>".
"""
import os
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "Scripts"))
import ship_sysroot_inputs as ship  # noqa: E402

clang, out = sys.argv[1], sys.argv[2]
rec = ship.load_recipe(ship.FAMILIES["glibc"])
for arch in rec["arches"]:
    env = ship.target_env(rec, arch, ship.GLIBC_DEFAULT)
    layout = ship.subst(rec["resource_layout"], env)
    os.makedirs(os.path.join(out, layout), exist_ok=True)
    open(os.path.join(out, layout, ship.subst(rec["builtins_name"], env)), "wb").close()
    triple = env["triple"]
    for spelling in (triple, triple.replace("-linux-", "-unknown-linux-", 1)):
        got = subprocess.run([clang, "--target=" + spelling, "-resource-dir=" + os.path.join(out, "compiler-rt"),
                              "-print-runtime-dir"], capture_output=True, text=True).stdout.strip()
        found = os.path.normpath(got) == os.path.normpath(os.path.join(out, layout))
        print(f"{arch} {spelling}: " + ("ok" if found else f"MISSING {got}"))
