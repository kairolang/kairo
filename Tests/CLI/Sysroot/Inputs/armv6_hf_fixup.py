"""Applies the runtimes template's fixups to stand-in targets and prints
whether each one matched and which flags its builtins ended up with.
Usage: armv6_hf_fixup.py <Scripts dir>."""
import sys
sys.path.insert(0, sys.argv[1])
import runtimes_template as rt


class Stub:
    def __init__(self, rt_arch, flt):
        self.P = {"cpu": "arm", "float": flt, "rt_arch": rt_arch, "libc": "musl"}
        flags = ["-DCOMPILER_RT_HAS_FLOAT16", "-O2"]
        self.tables = {"builtins": {"flags": {"c": list(flags), "asm": list(flags)}}}


for name, arch, flt in (("armv6-hard", "armv6", "hard"), ("armv6-soft", "armv6", "soft"),
                        ("armv7-hard", "armv7", "hard")):
    t = Stub(arch, flt)
    hit = [why for match, fix, why in rt.FIXUPS if match(t) and fix(t) is None]
    for match, fix, why in rt.FIXUPS:   # a second pass must not repeat the define
        if match(t):
            fix(t)
    c = t.tables["builtins"]["flags"]["c"]
    a = t.tables["builtins"]["flags"]["asm"]
    print(name, "fixups", len(hit), "c", c.count("-DCOMPILER_RT_ARMHF_TARGET"),
          "asm", a.count("-DCOMPILER_RT_ARMHF_TARGET"))
