#!/usr/bin/env python3
# Colon case labels -> braced arms with `,` alternation.
#
#     case A:        case B:              case A, B, C, D {
#     case C:        case D:        ->        return true;
#         return true;                    }
#     default:                             default {
#         return false;                        return false;
#                                          }
#
# Line-based, not masked: a label line is `case <pat>:` and nothing else, and a
# line that has any leftover text after the labels are stripped is skipped.
import sys, os, re
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kairo_lex import run

# (?<!:) and (?!:) together pin the terminator to a LONE colon, so the `::` in
# `TokenKind::TkEof` is never mistaken for the end of the label.
CASE_SEG = re.compile(r"case\s+(.+?)\s*(?<!:):(?!:)")
DEFAULT_LBL = re.compile(r"^\s*default\s*:\s*$")


def _label_line(line):
    """List of patterns if the line is ONLY case labels, else None."""
    if DEFAULT_LBL.match(line):
        return []                       # empty list == `default`
    segs = CASE_SEG.findall(line)
    if not segs:
        return None
    if CASE_SEG.sub("", line).strip():  # leftover text -> has a body, skip
        return None
    return [s.strip() for s in segs]


def rewrite(src, path, report):
    lines = src.split("\n")
    out = []
    i = 0
    n = len(lines)
    count = 0

    while i < n:
        pats = _label_line(lines[i])
        if pats is None:
            out.append(lines[i])
            i += 1
            continue

        indent = lines[i][: len(lines[i]) - len(lines[i].lstrip())]
        is_default = pats == []
        groups = [pats]          # one group per source line, to keep the shape

        # gather consecutive label lines of the same flavour
        while i + 1 < n:
            nxt = _label_line(lines[i + 1])
            if nxt is None or (nxt == []) != is_default:
                break
            groups.append(nxt)
            i += 1
        i += 1

        # body: everything indented deeper than the label, up to the next label
        body = []
        while i < n:
            ln = lines[i]
            if ln.strip() and (len(ln) - len(ln.lstrip())) <= len(indent):
                break
            if _label_line(ln) is not None:
                break
            body.append(ln)
            i += 1
        while body and not body[-1].strip():
            i -= 1
            body.pop()

        if is_default:
            out.append(f"{indent}default {{")
        else:
            # Alternation is `,` -- PatternParse.k:386 says so, and there is no
            # OpPipe in the pattern grammar. `|` would parse as bitwise-or on the
            # enum's underlying integer and match one fused value, silently.
            #
            # The trailing comma must end the line: PatternParse.k:215 consumes
            # it with SkipNL::After, so the newline is only skipped *after* a
            # comma, never before one.
            cont = indent + "     "
            for gi, g in enumerate(groups):
                last = gi == len(groups) - 1
                joined = ", ".join(g)
                prefix = f"{indent}case " if gi == 0 else cont
                out.append(prefix + joined + (" {" if last else ","))
        out += body
        out.append(indent + "}")
        count += 1

    return "\n".join(out), count


if __name__ == "__main__":
    sys.exit(run(rewrite, "colon case labels -> braced arms with ',' alternation"))
