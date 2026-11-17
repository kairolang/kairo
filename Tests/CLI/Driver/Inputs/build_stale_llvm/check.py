"""Drives build.py's cross-LLVM staleness rule (stale_llvm_choice) on fake trees.

    check.py <repo root> <scratch dir>

A fake build/cross-llvm/<target> holds only the VCSRevision.h (or PREBUILT)
an LLVM build writes; nothing is built or rebuilt. Prints what each case
chose, after the warning build.py itself prints.
"""
import importlib.util
import sys
from pathlib import Path

root, scratch = Path(sys.argv[1]), Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("build_under_test", root / "build.py")
build = importlib.util.module_from_spec(spec)
sys.argv = [str(root / "build.py")]
spec.loader.exec_module(build)
build.say = lambda msg: print(msg, flush=True)

T = "x86_64-linux-musl"
OLD = "8f7e268535dd8e82207b41a07a7fb685e7a79e1b"
PIN = "a47beecca7198bb65cc363bb2e674fdc68bd42ce"

vcs = scratch / "cross" / T / "llvm" / "include" / "llvm" / "Support"
vcs.mkdir(parents=True, exist_ok=True)
(vcs / "VCSRevision.h").write_text(
    f'#define LLVM_REVISION "{OLD}"\n#define LLVM_REPOSITORY "https://example.invalid/llvm-project"\n')
pre = scratch / "cross" / "aarch64-linux-musl"
pre.mkdir(parents=True, exist_ok=True)
(pre / "PREBUILT").write_text(f"llvm {PIN}\n")

print("built", build.cross_llvm_built_commit(T, scratch / "cross"))
print("prebuilt", build.cross_llvm_built_commit("aarch64-linux-musl", scratch / "cross"))
print("none", repr(build.cross_llvm_built_commit("riscv64-linux-musl", scratch / "cross")))


def asked(reply):
    def ask(prompt):
        print("asked:", prompt, flush=True)
        if reply is None:
            raise EOFError
        return reply
    return ask


never = asked("NOT ASKED")
print("fresh:", build.stale_llvm_choice(T, PIN, PIN, None, True, never))
print("unknown:", build.stale_llvm_choice(T, "", PIN, None, True, never))
print("flag use:", build.stale_llvm_choice(T, OLD, PIN, "use", True, never))
print("flag rebuild:", build.stale_llvm_choice(T, OLD, PIN, "rebuild", True, never))
print("no terminal:", build.stale_llvm_choice(T, OLD, PIN, None, False, never))
print("enter:", build.stale_llvm_choice(T, OLD, PIN, None, True, asked("")))
print("r:", build.stale_llvm_choice(T, OLD, PIN, None, True, asked("r")))
print("eof:", build.stale_llvm_choice(T, OLD, PIN, None, True, asked(None)))
