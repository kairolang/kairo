"""Instruction-count parity of the wrap and sequencing forms (parity.cpp).

Usage: parity.py <clang> <parity.cpp> [--table]

Each ref_X / k_X pair is compiled (-S, no unwind tables) and the
instructions between `name:` and its `.Lfunc_end` are counted. The general
pairs run at -O1, -O2 and -O3 for x86_64 and aarch64; the shift pairs
(`sh_`, SHIFT spec §8.3) at -O1, -O2, -Os and -Oz on SHIFT_TARGETS. Every
pair must match except ALLOW, the pairs whose difference is the semantics,
not overhead, and SHIFT_ALLOW, each entry the EXACT delta measured: a
change in either direction is a finding (a cheaper mask is as worth knowing
as a dearer one). `--table` prints every shift delta instead of checking.
Re-run on a clang upgrade.
"""
import re
import subprocess
import sys

# name -> the C++ UB (or semantic) the plain operator was exploiting.
ALLOW = {
    "div": "a runtime divisor's zero and -1 checks are the semantics",
}
TARGETS = ["x86_64-linux-gnu", "aarch64-linux-gnu"]
LEVELS = ["-O1", "-O2", "-O3"]

# Shift targets: name -> clang flags.
SHIFT_TARGETS = {
    "x86_64": ["--target=x86_64-linux-gnu"],
    "aarch64": ["--target=aarch64-linux-gnu"],
    "riscv64": ["--target=riscv64-linux-gnu"],
    "thumbv6m": ["--target=thumbv6m-none-eabi", "-mcpu=cortex-m0plus", "-mno-outline"],
    "thumbv7m": ["--target=thumbv7m-none-eabi", "-mcpu=cortex-m3", "-mno-outline"],
    "thumbv8.1m": ["--target=thumbv8.1m.main-none-eabi", "-mcpu=cortex-m55", "-mno-outline"],
    "armv7a": ["--target=armv7a-linux-gnueabihf", "-mno-outline"],
}
SHIFT_LEVELS = ["-O1", "-O2", "-Os", "-Oz"]
ARM32 = ["thumbv7m", "thumbv8.1m", "armv7a"]

# (pair, target) -> {level: delta} or one delta for every level; anything
# not named must be 0, so a constant count, a no_wrap range-loop count and a
# count the program masked itself are proven free on every target, ARM32
# included. Measured with clang 22 (build/llvm), -mno-outline on the ARM32
# targets so -Oz's machine outliner does not fold a function into a branch.
SHIFT_ALLOW = {}


def _allow(pairs, targets, delta):
    for p in pairs:
        for t in targets:
            SHIFT_ALLOW[(p, t)] = delta


# A runtime count's mask on ARM32, which shifts by the count's low byte: one
# AND, and on ARMv6-M two (no AND-immediate: `movs r, #31` first). 64-bit
# shifts there are libcall-free sequences that mask once too.
_RUNTIME = ["sh_shl8", "sh_lshr8", "sh_ashr8", "sh_shl32", "sh_lshr32", "sh_ashr32",
            "sh_shl64", "sh_lshr64", "sh_ashr64"]
_allow(_RUNTIME, ARM32, 1)
_allow(_RUNTIME, ["thumbv6m"], 2)
# `p[idx()] <<= n`: the call clobbers r0-r3, and ARMv6-M's 31 shares a
# register already materialized, so +1 there too.
_allow(["sh_place"], ARM32 + ["thumbv6m"], 1)
# A runtime count in a loop: the mask is hoisted out, paid once per loop
# entry on every target: even where the shift instruction masks in
# hardware, LLVM keeps the loop-invariant AND (hoisted) rather than fold it
# into the shifts; twice on ARMv6-M.
_allow(["sh_loop"], ["x86_64", "aarch64", "riscv64"] + ARM32, 1)
_allow(["sh_loop"], ["thumbv6m"], 2)
# 128-bit: an expanded multi-word shift, whose count-select sequence the
# mask perturbs by one instruction either way.
_allow(["sh_shl128", "sh_lshr128", "sh_ashr128"], ["aarch64"], {"-Oz": 1})
_allow(["sh_shl128", "sh_lshr128"], ["riscv64"], 1)
_allow(["sh_ashr128"], ["riscv64"], {"-O1": -1, "-O2": -1, "-Os": -1, "-Oz": 1})
# 128-bit on ARM32 (compiled there since the fork's __int128-on-32-bit patch,
# .patches/0004): the same two-half expansion either way, the mask's AND
# (ARMv6-M: movs #127 + ands) plus the copies -Oz's allocator spends
# keeping the masked count live; free at -O1, -O2 and -Os.
_allow(["sh_shl128"], ["thumbv7m", "armv7a", "thumbv6m"], {"-Oz": 2})
_allow(["sh_lshr128", "sh_ashr128"], ["thumbv7m", "armv7a"], {"-Oz": 1})
_allow(["sh_shl128", "sh_lshr128", "sh_ashr128"], ["thumbv8.1m"], {"-Oz": 1})
_allow(["sh_lshr128"], ["thumbv6m"], {"-Oz": 2})
_allow(["sh_ashr128"], ["thumbv6m"], {"-Oz": 3})


def counts(clang, src, flags, level):
    r = subprocess.run(
        [clang, "--driver-mode=g++", "-std=c++2c"] + flags + [level, "-S",
         "-fno-asynchronous-unwind-tables", "-o", "-", src],
        capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"parity: {' '.join(flags)} {level}: clang failed\n{r.stderr}")
    asm = r.stdout
    out = {}
    name = None
    for line in asm.splitlines():
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*):", line)
        if m and (m.group(1).startswith("ref_") or m.group(1).startswith("k_")):
            name = m.group(1)
            out[name] = 0
            continue
        if name is not None and line.startswith(".Lfunc_end"):
            name = None
            continue
        if name is not None and re.match(r"^\t[a-z]", line):
            out[name] += 1
    return out


def allowed(pair, target, level):
    a = SHIFT_ALLOW.get((pair, target), 0)
    if isinstance(a, dict):
        return a.get(level, 0)
    return a


def main():
    clang, src = sys.argv[1], sys.argv[2]
    table = "--table" in sys.argv[3:]
    bad = 0
    for target in TARGETS:
        for level in LEVELS:
            c = counts(clang, src, ["--target=" + target], level)
            for ref in sorted(n for n in c if n.startswith("ref_") and not n.startswith("ref_sh_")):
                pair = ref[4:]
                k = "k_" + pair
                if k not in c:
                    print(f"{target} {level} {pair}: no {k}")
                    bad += 1
                    continue
                if c[ref] != c[k] and pair not in ALLOW:
                    print(f"{target} {level} {pair}: ref {c[ref]} vs k {c[k]}")
                    bad += 1
    for target, flags in SHIFT_TARGETS.items():
        for level in SHIFT_LEVELS:
            c = counts(clang, src, flags, level)
            for ref in sorted(n for n in c if n.startswith("ref_sh_")):
                pair = ref[4:]
                k = "k_" + pair
                if k not in c:
                    print(f"{target} {level} {pair}: no {k}")
                    bad += 1
                    continue
                d = c[k] - c[ref]
                if table:
                    if d != 0:
                        print(f"{target} {level} {pair}: ref {c[ref]} k {c[k]} delta {d:+d}")
                    continue
                if d != allowed(pair, target, level):
                    print(f"{target} {level} {pair}: ref {c[ref]} vs k {c[k]}, delta {d:+d}, allowed {allowed(pair, target, level):+d}")
                    bad += 1
    if table:
        return 0
    print("parity: OK" if bad == 0 else f"parity: {bad} mismatch(es)")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
