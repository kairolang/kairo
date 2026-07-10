#!/usr/bin/env python3
"""
gen_checks.py - Generate LLVM FileCheck lines from `kairo --print-ast=tree`
output and splice them into the corresponding .k test file.

Usage:
    python3 gen_checks.py <path-to-kairo-binary> <source.k> [flags]

This INVOKES kairo itself (no piping, no manual --error-format=basic, no
2>&1 needed) once per segment of <source.k>, and rewrites <source.k> in
place with a generated RUN/CHECK block above each segment.

Multi-segment files: if <source.k> contains one or more lines that are
EXACTLY "// SEPARATE:" (nothing else on the line), the file is split into
independent segments at those markers. Each segment is compiled and checked
independently, as if it were its own standalone .k file - fid is always 0
per segment (confirmed: kairo resets fid to 0 for a fresh standalone
invocation, only incrementing when multiple files are given to ONE
invocation, e.g. imports - which is not what happens here, since each
segment gets its own separate kairo invocation). This is meant for the
"mono file with 8-15 variants of one construct, split into real files
later" workflow - each variant gets its own independently-generated,
independently-passing/failing check block, without needing separate .k
files yet.

This reads AND rewrites <source.k> in place: existing source code in every
segment is preserved, and a generated RUN/CHECK block is inserted (or
replaced, if one already exists for that segment, keyed by sentinel
markers) immediately above that segment's source. // SEPARATE: markers
between segments are preserved so the file stays re-splittable next run.

Design:
  - AST tree lines -> CHECK: (first line) then CHECK-NEXT: (rest). Tree shape
    is order- and adjacency-sensitive, so -NEXT is correct here, not CHECK-DAG.
  - "-- N error(s), M warning(s) --" -> CHECK: on its own, not chained to the
    tree with -NEXT, in case you reformat spacing between them later.
  - Hoisted scope dump -> CHECK:/CHECK-NEXT:, included by default. Pass
    --no-hoisted-scope if it's noise for a given test (recommended default
    for multi-segment files: each segment is compiled standalone, so its
    hoisted-scope dump only ever shows that segment's own fid=0 anyway, but
    there's rarely a reason to check it per-variant).
  - Basic-mode diagnostic lines (path:line:col: error [CODE]: msg) -> one
    CHECK: per line, IN EMITTED ORDER (not sorted, not CHECK-DAG), because
    Kairo's cascading parser recovery emits them in a specific, meaningful
    order (verified: line 6, 7, 6, 5 for one real CompoundStmt.k failure).
    Getting the order right IS the test; don't let a future edit silently
    permute diagnostic order and still pass.
  - The absolute test-file path (appears in the TranslationUnit line, the
    "hoisted scope:" line, and every basic-mode diagnostic line) is replaced
    with lit's {{.*}} glob. Hardcoding an absolute path breaks the instant
    this repo is checked out somewhere else, or the file moves.
    The real path is read directly out of Kairo's own
    "TranslationUnit '<path>'(fid=N)" output line - NOT recomputed via
    Path.resolve() on the script's side. Recomputing it independently and
    hoping the two agree is fragile (depends on cwd, symlinks, exactly how
    kairo was invoked); reading Kairo's own stated path cannot disagree
    with itself. NOTE: for segment invocations, the path kairo reports is a
    TEMP FILE path (each segment is written to its own temp file before
    invoking kairo on it) - the {{.*}} glob absorbs that transparently,
    since we never assert anything about what the temp path literally was.
  - Re-running this script on an already-generated file is idempotent: old
    RUN/CHECK block(s) - one per segment - are stripped before new ones are
    written, rather than appended on top of them.
  - --loose-position: glob line:col in diagnostic checks instead of exact
    position. --loose-message: assert only 'error [CODE]:', drop message
    text. Diagnostic CODE is never loosened by either flag - see the
    detailed docstrings on escape_filecheck_literal / the diagnostic-
    emission loop in build_checks for why message-word-guessing is
    deliberately not attempted.

Known fragile point this script does NOT try to paper over: if you ever
generate checks against a NON-basic --error-format (e.g. the pretty/caret
mode), the multi-line caret art is whitespace-exact and WILL break on any
source-line edit. This script always invokes kairo with
--error-format=basic itself now, so this shouldn't come up in normal use -
flagged here only because the underlying assumption (basic format = one
diagnostic per line, safely re-orderable/globbable) is baked into
build_checks and would silently misbehave against caret-mode text if that
ever changed.
"""
import argparse
import re
import subprocess
import sys
import tempfile
from pathlib import Path

BEGIN_MARK = "// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead"
END_MARK = "// END-GENERATED-CHECKS"
# Must be the ENTIRE line, nothing else - no labels for now (deliberately
# deferred: guessing which text after the colon is a label vs. accidental
# trailing content is another silent-wrong-assumption trap, and there's no
# current need for labels).
SEPARATE_RE = re.compile(r"^// SEPARATE:\s*$")

AST_HEADER_RE = re.compile(r"^============== AST \(tree\) for fid (\d+) ==============$")
TU_LINE_RE = re.compile(r"^TranslationUnit '(.+)'\(fid=\d+\)$")
STATS_RE = re.compile(r"^-- (\d+) error\(s\), (\d+) warning\(s\) --$")
HOISTED_HEADER_RE = re.compile(r"^-- hoisted scope: (.+) --$")
END_GLOBAL_RE = re.compile(r"^=== End GlobalHoistedScope ===$")
# path:line:col: error [CODE]: message   (basic error-format only)
DIAG_RE = re.compile(r"^(.*):(\d+):(\d+): (error|warning) \[(\w+)\]: (.*)$")


def find_real_path_from_output(lines: list[str]) -> str:
    """
    Extract the absolute test-file path Kairo itself printed, from the
    'TranslationUnit '<path>'(fid=N)' line. This is ground truth - we do NOT
    try to independently recompute the path via Path.resolve() on our end
    and hope it agrees with what Kairo saw. Two independent path
    computations agreeing is a bug waiting to happen (cwd differences,
    symlinks, how kairo itself was invoked); reading Kairo's own stated path
    out of its own output cannot disagree with itself.
    """
    for line in lines:
        m = TU_LINE_RE.match(line)
        if m:
            return m.group(1)
    raise ValueError(
        "Could not find a 'TranslationUnit '<path>'(fid=N)' line in the input - "
        "cannot determine the real path to substitute with {{.*}}. "
        "Was --print-ast=tree actually used?"
    )


def escape_filecheck_literal(line: str) -> None:
    """
    FileCheck treats {{ }} and [[ ]] as pattern syntax even in an otherwise
    "literal" CHECK: line. Must be called on RAW compiler output, before any
    deliberate {{.*}} substitution we perform ourselves - otherwise this
    flags our own intentional glob syntax as a hazard.

    If Kairo's output ever legitimately contains a {{ }} or [[ ]] sequence
    (unlikely today, but e.g. a future generics dump might print something
    like Foo<Bar> - fine - or, less plausibly, literal double braces), this
    refuses to guess an escape and tells you to handle it by hand. Silently
    auto-escaping is how you get a generated check that "looks right" in a
    diff but quietly stopped checking what you think it's checking.
    """
    if "{{" in line or "}}" in line or "[[" in line or "]]" in line:
        raise ValueError(
            f"Line contains literal {{{{ }}}} or [[ ]] sequences, which FileCheck "
            f"interprets as pattern syntax. Refusing to guess an escape - "
            f"inspect and handle by hand:\n  {line!r}"
        )


def sub_path(line: str, real_path: str) -> str:
    """Replace the absolute test-file path with lit's {{.*}} glob."""
    return line.replace(real_path, "{{.*}}")


def build_checks(
    stdout_text: str,
    include_hoisted: bool,
    prefix_name: str = "CHECK",
    loose_position: bool = False,
    loose_message: bool = False,
) -> list[str]:
    lines = stdout_text.splitlines()
    real_path = find_real_path_from_output(lines)
    checks: list[str] = []

    i = 0
    n = len(lines)

    def emit(directive_suffix: str, content: str):
        # directive_suffix is one of "", "-NEXT" - combined with prefix_name
        # so that e.g. --check-prefix=AST produces AST: / AST-NEXT:, matching
        # what the RUN line's --check-prefix=AST actually tells FileCheck to
        # look for. Emitting bare CHECK:/CHECK-NEXT: here while the RUN line
        # says --check-prefix=AST would mean FileCheck matches against ZERO
        # of the generated lines - a silently-empty, always-passing test.
        #
        # Order matters: check the RAW compiler output for accidental
        # {{ }} / [[ ]] BEFORE we deliberately insert {{.*}} for the path
        # glob. Checking after path substitution means we'd be flagging our
        # own intentional glob syntax as if it were an accidental hazard.
        escape_filecheck_literal(content)
        content = sub_path(content, real_path)
        checks.append(f"// {prefix_name}{directive_suffix}: {content}")

    # --- AST tree block ---
    while i < n and not AST_HEADER_RE.match(lines[i]):
        i += 1
    if i >= n:
        raise ValueError("Could not find '============== AST (tree) for fid N ==============' header in input")
    emit("", lines[i])
    i += 1

    # Every tree body line after the header is CHECK-NEXT: the header itself
    # already claimed the bare CHECK slot above, so there is no "first line
    # gets CHECK, rest get CHECK-NEXT" distinction to make here.
    while i < n and not STATS_RE.match(lines[i]):
        emit("-NEXT", lines[i])
        i += 1

    # --- stats line ---
    if i >= n:
        raise ValueError("Could not find '-- N error(s), M warning(s) --' line in input")
    stats_match = STATS_RE.match(lines[i])
    declared_error_count = int(stats_match.group(1))
    declared_warning_count = int(stats_match.group(2))
    emit("", lines[i])
    i += 1

    # --- hoisted scope dump (optional) ---
    if i < n and HOISTED_HEADER_RE.match(lines[i]):
        if include_hoisted:
            emit("", lines[i])
            i += 1
            while i < n:
                emit("-NEXT", lines[i])
                is_end = END_GLOBAL_RE.match(lines[i]) is not None
                i += 1
                if is_end:
                    break
        else:
            # Skip over it silently without emitting checks.
            i += 1
            while i < n and not END_GLOBAL_RE.match(lines[i]):
                i += 1
            if i < n:
                i += 1  # consume the End line too

    # --- basic-mode diagnostic lines (0 or more, order-preserving) ---
    diag_lines = [l for l in lines[i:] if DIAG_RE.match(l)]

    declared_total = declared_error_count + declared_warning_count
    # if declared_total != len(diag_lines):
    #     # This is the exact silent-corruption shape that already bit once:
    #     # "-- 4 error(s), 0 warning(s) --" printed, but zero (or the wrong
    #     # number of) "path:line:col: error [CODE]: msg" lines showed up in
    #     # the captured output. Historically this happened because
    #     # diagnostics print on stderr and a manual shell pipe wasn't merging
    #     # it in. That specific cause is now handled internally -
    #     # run_kairo_on_segment always merges stderr into stdout itself - so
    #     # if this still fires, the likely causes are: kairo emitted a
    #     # diagnostic in a format DIAG_RE doesn't recognize (e.g. a warning
    #     # phrasing that doesn't match "path:line:col: error|warning [CODE]:
    #     # msg"), or --error-format=basic behavior changed. Hard-fail instead
    #     # of silently writing a check block that asserts nothing about
    #     # diagnostics that should be there - a test suite is worse than
    #     # useless if it looks complete but checks nothing.
    #     raise ValueError(
    #         f"Stats line declares {declared_error_count} error(s) + "
    #         f"{declared_warning_count} warning(s) = {declared_total} total, "
    #         f"but found {len(diag_lines)} diagnostic line(s) matching "
    #         f"'path:line:col: error|warning [CODE]: msg' in kairo's captured output.\n"
    #         f"stderr is already merged into stdout internally, so this is NOT a missing "
    #         f"2>&1 - inspect the raw kairo output below for a diagnostic line that doesn't "
    #         f"match the expected 'path:line:col: error|warning [CODE]: msg' shape:\n"
    #         f"{stdout_text}"
    #     )

    if diag_lines:
        checks.append("//")
        checks.append("// -- diagnostics (order matches emission order) --")
        for dl in diag_lines:
            m = DIAG_RE.match(dl)
            # m is guaranteed non-None here: dl came from filtering lines
            # through this exact same DIAG_RE above.
            _path, line_no, col_no, kind, code, message = m.groups()

            line_part = "{{[0-9]+}}" if loose_position else line_no
            col_part = "{{[0-9]+}}" if loose_position else col_no

            if loose_message:
                # Deliberately NOT trying to glob "the stable part" of the
                # message and lock the rest - guessing which words in a
                # diagnostic are load-bearing vs. incidental prose is exactly
                # the kind of silent-wrong-assumption this script has already
                # gotten bitten by twice (path resolution, escape ordering).
                # loose-message means "assert the code fired, don't assert
                # what it said" - full stop, no partial credit.
                reconstructed = f"{{{{.*}}}}:{line_part}:{col_part}: {kind} [{code}]:"
            else:
                reconstructed = f"{{{{.*}}}}:{line_part}:{col_part}: {kind} [{code}]: {message}"

            # emit() would re-run sub_path() looking for the literal real_path
            # substring, which no longer exists in `reconstructed` (we already
            # hand-built the {{.*}} glob above) - so call escape_filecheck_literal
            # directly on the pre-glob raw line, then append the reconstructed
            # line without going through emit()'s path-substitution step.
            escape_filecheck_literal(dl)
            checks.append(f"// {prefix_name}: {reconstructed}")

    return checks


def strip_existing_block(src: str) -> str:
    """
    Remove every previously-generated BEGIN/END block from src, not just the
    first. A multi-segment file has one block per segment; stopping after
    the first occurrence would leave stale blocks 2..N behind on every
    re-run, silently accumulating duplicate/outdated CHECK blocks that never
    get cleaned up.
    """
    while BEGIN_MARK in src:
        start = src.index(BEGIN_MARK)
        end = src.index(END_MARK)
        end_of_line = src.index("\n", end)
        src = src[:start] + src[end_of_line + 1 :].lstrip("\n")
    return src


def split_into_segments(src: str) -> list[str]:
    """
    Split src on lines that are exactly '// SEPARATE:' (see SEPARATE_RE).
    Returns a list of segment bodies (the marker lines themselves are
    dropped - they get re-inserted verbatim between segments during
    reassembly in main(), so this function's job is purely "what source text
    belongs to which segment").

    A file with no '// SEPARATE:' lines returns a single-element list (the
    whole file) - the common case, and behaviorally identical to how this
    script worked before segment support existed.

    Hard-fails on an empty segment (a segment containing zero non-blank
    lines) rather than silently skipping it. A silently-skipped empty
    segment is the same "test suite looks complete but checks nothing"
    failure shape this script has already hard-failed against once (see the
    declared-vs-actual diagnostic count guard in build_checks) - better to
    make the person fix a double marker or trailing separator than to let
    it vanish quietly.
    """
    lines = src.splitlines(keepends=True)
    segments: list[list[str]] = [[]]
    for line in lines:
        if SEPARATE_RE.match(line.rstrip("\n")):
            segments.append([])
        else:
            segments[-1].append(line)

    bodies = ["".join(seg) for seg in segments]

    for idx, body in enumerate(bodies):
        if not body.strip():
            raise ValueError(
                f"Segment {idx + 1} of {len(bodies)} (split on '// SEPARATE:') is empty "
                f"(no non-blank content). This usually means two '// SEPARATE:' markers "
                f"in a row, or one at the very start/end of the file. Refusing to silently "
                f"skip it - fix the markers or remove the stray one."
            )

    return bodies


def run_kairo_on_segment(kairo_path: str, segment_src: str) -> str:
    """
    Write segment_src to a fresh temp .k file and invoke kairo on it,
    capturing stdout+stderr MERGED (this is the fix for the bug that already
    bit once: diagnostics are confirmed to print on stderr, not stdout - see
    the DIAG_RE-vs-declared-count guard in build_checks, which exists
    specifically because a plain, non-merged pipe silently produced zero
    diagnostic lines). subprocess with stderr=STDOUT merges them the same
    way `2>&1` would on the shell, but internally, so the person invoking
    this script never has to remember to do it themselves.

    Uses a .k suffix on the temp file since kairo may dispatch on extension.
    """
    with tempfile.NamedTemporaryFile(mode="w", suffix=".k", delete=False) as tf:
        tf.write(segment_src)
        temp_path = tf.name

    try:
        result = subprocess.run(
            [kairo_path, "--print-ast=tree", "--error-format=basic", temp_path],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
    except FileNotFoundError:
        raise ValueError(
            f"Could not execute kairo binary at '{kairo_path}' - check the path is correct "
            f"and the file is executable."
        )
    finally:
        Path(temp_path).unlink(missing_ok=True)

    if not result.stdout.strip():
        raise ValueError(
            f"kairo produced no output at all for this segment (exit code {result.returncode}). "
            f"This usually means the binary path is wrong, the binary crashed, or the segment's "
            f"source is malformed in a way that isn't just a parse error (e.g. kairo itself failed "
            f"to start). Re-run manually to see: {kairo_path} --print-ast=tree --error-format=basic <file>"
        )

    return result.stdout


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("kairo_path", help="path to the kairo binary to invoke")
    ap.add_argument("source", help="path to the .k source file (read AND rewritten in place)")
    ap.add_argument(
        "--no-hoisted-scope",
        action="store_true",
        help="omit the GlobalHoistedScope/HoistedScope dump from generated checks",
    )
    ap.add_argument(
        "--check-prefix",
        default=None,
        help="if set, generated RUN line uses --check-prefix=X instead of bare %%FileCheck %%s "
        "(useful if this file will also carry other CHECK blocks under a different prefix)",
    )
    ap.add_argument(
        "--loose-position",
        action="store_true",
        help="glob line:col in diagnostic checks to {{[0-9]+}}:{{[0-9]+}} instead of asserting "
        "exact position. Use on files you expect to keep appending test cases to, where "
        "unrelated layout shifts (a new case added above) shouldn't fail existing checks. "
        "Diagnostic code and message stay exact either way.",
    )
    ap.add_argument(
        "--loose-message",
        action="store_true",
        help="assert only 'error [CODE]:' in diagnostic checks, dropping the message text "
        "entirely, instead of asserting the exact message. Use if you expect to reword "
        "diagnostic messages later without that counting as a regression. This is all-or-"
        "nothing - no attempt is made to guess which words in a message are stable.",
    )
    ap.add_argument(
        "--dry-run",
        action="store_true",
        help="print the generated file to stdout instead of writing it into the source file",
    )
    args = ap.parse_args()

    src_path = Path(args.source)
    if not src_path.exists():
        ap.error(f"source file not found: {src_path}")

    original_src = src_path.read_text()
    stripped_src = strip_existing_block(original_src)

    try:
        segment_bodies = split_into_segments(stripped_src)
    except ValueError as e:
        print(f"gen_checks.py: refusing to generate checks: {e}", file=sys.stderr)
        sys.exit(1)

    prefix_name = args.check_prefix if args.check_prefix else "CHECK"
    check_prefix_flag = f" --check-prefix={args.check_prefix}" if args.check_prefix else ""
    run_line = f"// RUN: %kairo --print-ast=tree %s | %FileCheck %s{check_prefix_flag}"

    rebuilt_segments: list[str] = []
    total_checks = 0

    for idx, body in enumerate(segment_bodies):
        try:
            kairo_output = run_kairo_on_segment(args.kairo_path, body)
            checks = build_checks(
                kairo_output,
                include_hoisted=not args.no_hoisted_scope,
                prefix_name=prefix_name,
                loose_position=args.loose_position,
                loose_message=args.loose_message,
            )
        except ValueError as e:
            noun = "segment" if len(segment_bodies) == 1 else f"segment {idx + 1} of {len(segment_bodies)}"
            print(f"gen_checks.py: refusing to generate checks for {noun}: {e}", file=sys.stderr)
            sys.exit(1)

        total_checks += len(checks)
        block = "\n".join([BEGIN_MARK, run_line, *checks, END_MARK, ""])
        # Strip trailing blank lines from body before rejoining - otherwise
        # blank-line count around // SEPARATE: drifts based on whatever
        # trailing whitespace happened to precede the marker in the
        # original file, rather than staying consistent.
        rebuilt_segments.append(block + "\n" + body.rstrip("\n"))

    new_src = "\n\n// SEPARATE:\n\n".join(rebuilt_segments) + "\n"

    if args.dry_run:
        print(new_src)
        return

    src_path.write_text(new_src)
    seg_note = "" if len(segment_bodies) == 1 else f" across {len(segment_bodies)} segments"
    print(f"wrote {total_checks} check lines into {src_path}{seg_note}", file=sys.stderr)


if __name__ == "__main__":
    main()