#!/usr/bin/env python3
# Pass manager for the v0.0.1 -> v0.1.0 migrations in this folder.
#
#     python3 Scripts/Migration/migrate.py private/portdry            # report
#     python3 Scripts/Migration/migrate.py private/portdry --apply    # rewrite
#     python3 Scripts/Migration/migrate.py --list
#
# Every file is read once, threaded through every enabled pass in PIPELINE
# order in memory, and written once. Each pass still sees exactly what it would
# have seen run on its own after the passes before it -- this is the scripts
# run back to back, minus the re-reading.
#
# Options:
#   --apply              write the result (default: report only)
#   --only SUBSTR        only paths containing SUBSTR
#   --passes a,b         run only these passes (still in pipeline order)
#   --skip a,b           run everything enabled except these
#   --from NAME          start the pipeline at NAME ...
#   --to NAME            ... and stop after NAME (inclusive)
#   --with-stubs         enable stub_ffi_imports (dry-run aid, off by default)
#   --with-libcxx        enable libcxx_to_cxx_std (Stage 1.5, off by default)
#   --all                forwarded: split_oneliner_blocks splits
#                        single-statement blocks too
#   --no-stage0-safe     forwarded: redundant_parens uses pure Stage 1
#                        precedence. Its default is STAGE 0 SAFE -- see
#                        redundant_parens.py --help before passing this
#   --log-bail           forwarded: redundant_parens lists every pair it kept
#                        because it could not parse the interior
#   --check-idempotent   run the pipeline a second time over its own output
#                        and list every file that changes again
#   --selftest           run each pass's own --selftest table, touch nothing
#   --in-place           allow --apply on Compiler/, Lib/ or Linker/ itself
#   --list               print the pipeline and exit
#
# One pass per script is deliberate (README): when Stage 1 chokes on a
# migrated file, a single rule has to be suspectable and re-runnable against a
# fresh copy. --passes / --from / --to are that re-run; this file only saves
# typing the sequence.
import ast, importlib, os, sys, traceback

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from kairo_lex import walk


# --------------------------------------------------------------------------
# The order. Each line says why it sits where it does; a pass with no reason
# is order-independent and only placed for a stable report.
# --------------------------------------------------------------------------
class Pass:
    def __init__(self, name, why, loader="standard", opt_in=None):
        self.name, self.why, self.loader, self.opt_in = name, why, loader, opt_in
        self.rewrite = None
        self.module = None


PIPELINE = [
    # inline C++ retirement first: both produce Kairo code from C++ strings,
    # and every later pass should see that code as code.
    Pass("template_alias_macros",
         "expands `#define B_T B<T>` into Kairo types before anything reads them"),
    Pass("inline_cpp_casts",
         "__inline_cpp(\"(T)x\") -> x as T; wants the Stage 0 string spelling, so before hex escapes"),
    Pass("hex_escapes_to_chars",
         "normalizes string contents once the passes matching on Stage 0 spellings are done"),

    # Statement shape. README run order.
    Pass("ternary_to_if",
         "emits braced if/else; before switch_to_match so arm bodies are already final"),
    Pass("switch_to_match",
         "switch -> match and colon labels -> braced arms (subsumes case_labels_to_arms)"),
    Pass("stub_ffi_imports",
         "DRY-RUN AID ONLY -- comments ffi imports out; never on a tree you keep",
         opt_in="--with-stubs"),
    Pass("drop_turbofish", "Foo::<T> -> Foo<T>"),
    Pass("ranged_for_binding", "for x: T in -> for var x: T in"),
    Pass("qualified_var_binding", "static/const/eval var -> static/const/eval"),

    # Declarations.
    Pass("ref_and_mref",
         "ref!/mref in parameters -> @inout/@move, returns of the own type -> Self",
         loader="legacy"),
    Pass("libcxx_to_cxx_std",
         "Stage 1.5: libcxx:: -> cxx::std::; needs ffi imports added by hand",
         loader="libcxx", opt_in="--with-libcxx"),
    Pass("defaulted_fn_suffix",
         "default/delete prefix -> `= default`/`= delete`; before visibility_first "
         "so the modifier run it reorders is final"),
    Pass("visibility_first", "pub/priv/prot lead the modifier run"),

    # Expressions.
    Pass("redundant_parens",
         "drops parens precedence makes redundant (Stage 0 safe unless "
         "--no-stage0-safe); after ternary_to_if/switch_to_match so it sees "
         "the final statement heads, before layout"),

    # Layout last: it formats the output of everything above.
    Pass("split_oneliner_blocks",
         "one statement per line; last, so it sees every block the others produced"),
]

# Not in the pipeline, and why -- printed by --list so nobody re-adds them.
LEFT_OUT = {
    "case_labels_to_arms": "superseded by switch_to_match (a no-op after it, and not masked)",
}


# --------------------------------------------------------------------------
# Loaders. Most scripts export rewrite(src, path, report) -> (src, count).
# --------------------------------------------------------------------------
def load_standard(p):
    p.module = importlib.import_module(p.name)
    p.rewrite = p.module.rewrite


def load_legacy(p):
    # ref_and_mref.py walks sys.argv[1] and WRITES at module top level, so
    # importing it would rewrite whatever argv[1] happens to be. Execute only
    # its imports, constants and functions.
    path = os.path.join(HERE, p.name + ".py")
    with open(path, encoding="utf-8") as fh:
        tree = ast.parse(fh.read(), path)
    keep = (ast.Import, ast.ImportFrom, ast.FunctionDef, ast.ClassDef, ast.Assign)
    tree.body = [n for n in tree.body if isinstance(n, keep)]
    ns = {"__name__": p.name, "__file__": path}
    exec(compile(tree, path, "exec"), ns)

    def rewrite(src, path, report):
        s1, n1 = ns["rewrite_params"](src)
        s2, n2 = ns["rewrite_returns"](s1)
        return s2, n1 + n2
    p.rewrite = rewrite


def load_libcxx(p):
    mod = importlib.import_module(p.name)

    def rewrite(src, path, report):
        ok, cpp = mod.mask(src)
        live = [m for m in mod.SYM.finditer(src) if ok[m.start()]]
        dead = sum(1 for m in mod.SYM.finditer(src)
                   if not ok[m.start()] and any(a <= m.start() < b for a, b in cpp))
        if dead:
            report.append(f"{path}: {dead} libcxx:: site(s) in inline \"c++\" (MANUAL)")
        if live:
            report.append(f"{path}: run libcxx_to_cxx_std.py for the ffi imports it needs")
        return (mod.rewrite(src, live) if live else src), len(live)
    p.module = mod
    p.rewrite = rewrite


LOADERS = {"standard": load_standard, "legacy": load_legacy, "libcxx": load_libcxx}


# --------------------------------------------------------------------------
# Driver
# --------------------------------------------------------------------------
def opt(args, flag):
    if flag not in args:
        return None
    i = args.index(flag)
    if i + 1 >= len(args):
        sys.exit(f"{flag} needs a value")
    return args[i + 1]


def select(args):
    names = [p.name for p in PIPELINE]

    def check(xs):
        bad = [x for x in xs if x not in names]
        if bad:
            sys.exit(f"unknown pass(es): {', '.join(bad)}  (see --list)")
        return xs

    chosen = [p for p in PIPELINE if p.opt_in is None or p.opt_in in args]
    only = opt(args, "--passes")
    if only:
        wanted = check(only.split(","))
        # Naming an opt-in pass explicitly enables it.
        chosen = [p for p in PIPELINE if p.name in wanted]
    skip = opt(args, "--skip")
    if skip:
        drop = set(check(skip.split(",")))
        chosen = [p for p in chosen if p.name not in drop]
    lo, hi = opt(args, "--from"), opt(args, "--to")
    if lo:
        check([lo])
        chosen = [p for p in chosen if names.index(p.name) >= names.index(lo)]
    if hi:
        check([hi])
        chosen = [p for p in chosen if names.index(p.name) <= names.index(hi)]
    return chosen


def list_pipeline(args):
    on = {p.name for p in select(args)}
    for i, p in enumerate(PIPELINE, 1):
        mark = "*" if p.name in on else " "
        extra = f"  [needs {p.opt_in}]" if p.opt_in else ""
        print(f"{mark} {i:2d}. {p.name:24s}{extra}\n        {p.why}")
    print("\nnot in the pipeline:")
    for n, why in LEFT_OUT.items():
        print(f"      {n:24s} {why}")
    print("\n* = enabled with these flags")


def selftest(passes):
    rc = 0
    for p in passes:
        fn = getattr(p.module, "selftest", None) if p.module else None
        if fn is None:
            continue
        print(f"== {p.name}")
        rc |= fn() or 0
    return rc


def run_pipeline(passes, src, rel, reports, counts=None):
    for p in passes:
        before = src
        try:
            src, n = p.rewrite(src, rel, reports.setdefault(p.name, []))
        except Exception as ex:
            # One pass failing on one file must not take the others down; keep
            # the text from before it and say so.
            reports.setdefault(p.name, []).append(
                f"{rel}: CRASHED ({type(ex).__name__}: {ex}) -- pass skipped for this file")
            if "--verbose" in sys.argv:
                traceback.print_exc()
            src, n = before, 0
        if counts is not None and n:
            c = counts.setdefault(p.name, [0, 0])
            c[0] += n
            c[1] += 1
    return src


def guard_in_place(root, args):
    if "--apply" not in args or "--in-place" in args:
        return
    repo = os.path.realpath(os.path.join(HERE, "..", ".."))
    real = os.path.realpath(root)
    live = {repo} | {os.path.join(repo, d) for d in ("Compiler", "Lib", "Linker")}
    if real in live or any(real.startswith(d + os.sep) for d in live - {repo}):
        sys.exit(f"refusing --apply on {root}: that tree is Stage 0 source, and Stage 0\n"
                 "is what compiles it. Run on a copy (README), or pass --in-place.")


def main():
    args = sys.argv[1:]
    if "--list" in args:
        list_pipeline(args)
        return 0

    passes = select(args)
    for p in passes:
        LOADERS[p.loader](p)

    if "--selftest" in args:
        return selftest(passes)

    roots = [a for a in args if not a.startswith("--")
             and a not in {opt(args, f) for f in ("--only", "--passes", "--skip", "--from", "--to")}]
    if len(roots) != 1:
        # The header comment IS the usage text.
        with open(__file__, encoding="utf-8") as fh:
            for ln in fh.read().split("\n")[1:]:
                if not ln.startswith("#"):
                    break
                print(ln[2:])
        return 2
    root = roots[0]
    guard_in_place(root, args)
    apply = "--apply" in args

    files = walk(root, opt(args, "--only"))
    counts, reports, changed, unstable = {}, {}, [], []

    for path in files:
        rel = os.path.relpath(path, root)
        with open(path, encoding="utf-8") as fh:
            src = fh.read()
        new = run_pipeline(passes, src, rel, reports, counts)
        if new != src:
            changed.append(rel)
            if apply:
                with open(path, "w", encoding="utf-8") as fh:
                    fh.write(new)
        if "--check-idempotent" in args:
            if run_pipeline(passes, new, rel, {}) != new:
                unstable.append(rel)

    print(f"{'pass':26s} {'sites':>7s} {'files':>6s}")
    for p in passes:
        n, f = counts.get(p.name, [0, 0])
        print(f"{p.name:26s} {n:7d} {f:6d}")
    print(f"\n{len(changed)} of {len(files)} file(s) changed")

    for p in passes:
        rs = reports.get(p.name)
        if rs:
            print(f"\n{p.name}: {len(rs)} to look at by hand")
            for r in rs:
                print("  " + r)

    if "--check-idempotent" in args:
        print(f"\nidempotency: {len(unstable)} file(s) change on a second run")
        for r in unstable:
            print("  " + r)

    if not apply:
        print("\n(report only -- pass --apply to rewrite)")
    return 1 if unstable else 0


if __name__ == "__main__":
    sys.exit(main())
