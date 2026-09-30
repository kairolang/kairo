#!/usr/bin/env python3
# switch -> match, and colon case labels -> braced arms.
#
#     switch pk {                                  match pk {
#         case A:                                      case A,
#         case B: return "B";                               B {
#         case C: x = 1; break;               ->           return "B";
#         default: return "?";                         } case C {
#     }                                                    x = 1;
#                                                      } default {
#                                                          return "?";
#                                                      }
#                                                  }
#
# The keyword: STATEMENT position only -- nothing but whitespace (or `eval`)
# before it on the line -- so a `switch` used as an identifier, a field name or
# inside an expression is left alone.
#
# The arms: rewritten inside every `switch` AND every `match` block, so the
# pass is idempotent and still does the arm half on a tree an earlier version
# of this script already renamed. A `case X {` arm is already in the target
# form and stays byte-identical unless colon labels stacked onto it.
#
# match has no fallthrough, so what C-style fallthrough expressed is spelled
# another way or refused:
#   - Stacked empty labels are `,` alternation on the arm they fell into, one
#     source line per pattern line. The trailing comma must END the line:
#     PatternParse consumes it with SkipNL::After, so a newline is skipped
#     only after a comma, never before one. `|` would parse as bitwise-or on
#     the enum's integer and match one fused value, silently.
#   - A trailing `break;` is dropped. Inside match it would break the
#     ENCLOSING loop.
#   - Any other `break` that is not inside a nested loop is reported: it
#     targeted the switch and now targets a loop, and only a human can tell
#     what it meant.
#   - A colon arm whose body does not end in return/break/continue/throw/...
#     and is not the last arm genuinely falls through into the next body.
#     The whole switch is reported and its arms left alone.
#   - `case A:` stacked onto `default:` is dropped (default catches it) and
#     reported.
#
# Layout of rewritten arms: consecutive converted arms chain as
# `} case X {`; a blank line or comment between two arms stops the chain and
# is kept. Comment lines between stacked labels are kept, blank ones dropped.
import sys, os, re
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kairo_lex import code_mask, kw_at, run
from split_oneliner_blocks import Line, statements

# kairo_lex does not know char literals, and `case ':'` / `case '{'` would
# otherwise end a label or open a block.
CHAR_LIT = re.compile(r"'(?:\\(?:x[0-9A-Fa-f]{2}|u\{?[0-9A-Fa-f]+\}?|.)|[^'\\\n])'")
TERMINATORS = re.compile(
    r"(return|break|continue|throw|panic|goto|ICE_FAIL|ICE_UNREACHABLE|"
    r"(?:std::)?unreachable|(?:std::)?abort)\b")
LOOPS = ("for", "while", "loop", "do", "switch", "match")


class Skip(Exception):
    pass


def full_mask(src):
    mask = code_mask(src)
    for m in CHAR_LIT.finditer(src):
        if all(mask[k] for k in range(m.start(), m.end())):
            for k in range(m.start(), m.end()):
                mask[k] = False
    return mask


def line_of(src, pos):
    return src.count("\n", 0, pos) + 1


def line_indent(src, pos):
    ls = src.rfind("\n", 0, pos) + 1
    j = ls
    while j < len(src) and src[j] in " \t":
        j += 1
    return src[ls:j]


def match_close(src, mask, open_at):
    """Offset of the bracket closing the one at open_at."""
    depth = 0
    for i in range(open_at, len(src)):
        if not mask[i]:
            continue
        if src[i] in "([{":
            depth += 1
        elif src[i] in ")]}":
            depth -= 1
            if depth == 0:
                return i
    raise Skip("unbalanced brackets")


def stmt_keywords(src, mask):
    """(start, end, word) of each statement-position switch/match."""
    out = []
    for m in re.finditer(r"\b(switch|match)\b", src):
        p = m.start()
        if not all(mask[k] for k in range(p, m.end())):
            continue
        ls = src.rfind("\n", 0, p) + 1
        if src[ls:p].strip() not in ("", "eval"):
            continue
        out.append((p, m.end(), m.group(1)))
    return out


def block_of(src, mask, kw_end):
    """(open, close) of the block after the scrutinee."""
    depth = 0
    for i in range(kw_end, len(src)):
        if not mask[i]:
            continue
        c = src[i]
        if c == "{" and depth == 0:
            return i, match_close(src, mask, i)
        if c in "([":
            depth += 1
        elif c in ")]":
            depth -= 1
        elif c in ";}":
            break
    raise Skip("no block after the scrutinee")


def next_arm(src, mask, i, hi):
    """First depth-0 `case`/`default` in [i, hi), or hi."""
    depth = 0
    while i < hi:
        if mask[i]:
            c = src[i]
            if c in "([{":
                depth += 1
            elif c in ")]}":
                depth -= 1
            elif depth == 0 and (kw_at(src, mask, i, "case") or kw_at(src, mask, i, "default")):
                return i
        i += 1
    return hi


def head_end(src, mask, i, hi):
    """First depth-0 `{` or lone `:` after a case keyword."""
    depth = 0
    while i < hi:
        if mask[i]:
            c = src[i]
            if depth == 0 and c == "{":
                return i
            if (depth == 0 and c == ":" and src[i - 1] != ":"
                    and (i + 1 >= len(src) or src[i + 1] != ":")):
                return i
            if c in "([":
                depth += 1
            elif c in ")]":
                depth -= 1
        i += 1
    raise Skip("case label with neither `:` nor `{`")


def last_code(src, mask, lo, hi):
    """Offset one past the last non-space code byte in [lo, hi), or lo."""
    k = hi - 1
    while k >= lo and ((not mask[k]) or src[k].isspace()):
        k -= 1
    return k + 1


def parse_arms(src, mask, lo, hi):
    arms = []
    i = next_arm(src, mask, lo, hi)
    while i < hi:
        kind = "case" if kw_at(src, mask, i, "case") else "default"
        j = i + len(kind)
        if kind == "default":
            while j < hi and src[j].isspace():
                j += 1
            if j >= hi or src[j] not in ":{" or not mask[j]:
                raise Skip("`default` with neither `:` nor `{`")
            h = j
        else:
            h = head_end(src, mask, j, hi)
        arm = {"kind": kind, "start": i, "head": h, "line": line_of(src, i),
               "pattern": src[i + len(kind):h].strip() if kind == "case" else ""}
        if src[h] == "{":
            arm["form"] = "brace"
            arm["end"] = match_close(src, mask, h) + 1
            nxt = next_arm(src, mask, arm["end"], hi)
        else:
            arm["form"] = "colon"
            nxt = next_arm(src, mask, h + 1, hi)
            code_end = last_code(src, mask, h + 1, nxt)
            # Extend to the end of the last code line, so a trailing comment
            # stays with its statement (or, on an empty label, its pattern).
            eol = src.find("\n", max(code_end, h + 1), nxt)
            arm["end"] = eol if eol >= 0 else last_code(src, [True] * len(src), h + 1, nxt)
            arm["empty"] = code_end == h + 1
        arms.append(arm)
        i = nxt
    return arms


def loop_ranges(src, mask, lo, hi):
    """Bodies of nested loops and switches in [lo, hi): a `break` inside one
    targets that construct, not the arm's switch."""
    out = []
    for i in range(lo, hi):
        if not mask[i] or not any(kw_at(src, mask, i, w) for w in LOOPS):
            continue
        depth = 0
        for j in range(i, hi):
            if not mask[j]:
                continue
            if src[j] == "{" and depth == 0:
                out.append((j, match_close(src, mask, j)))
                break
            if src[j] in "([":
                depth += 1
            elif src[j] in ")]":
                depth -= 1
            elif src[j] in ";}":
                break
    return out


def stray_breaks(src, mask, lo, hi):
    loops = loop_ranges(src, mask, lo, hi)
    return [i for i in range(lo, hi)
            if kw_at(src, mask, i, "break") and not any(a < i < b for a, b in loops)]


def trailing_break(src, mask, lo, hi):
    """(start, end) of a final `break;` in [lo, hi), or None."""
    e = last_code(src, mask, lo, hi)
    k = e
    if k > lo and src[k - 1] == ";":
        k = last_code(src, mask, lo, k - 1)
    if k - lo >= 5 and kw_at(src, mask, k - 5, "break"):
        return k - 5, e
    return None


def body_lines(src, mask, lo, hi, indent, unit):
    """A colon arm's body [lo, hi) as lines at indent+unit. The first line may
    be inline after the `:`; later lines are re-indented as a block."""
    text, m = src[lo:hi], mask[lo:hi]
    nl = text.find("\n")
    inline = Line(text, m) if nl < 0 else Line(text[:nl], m[:nl])
    rest = "" if nl < 0 else text[nl + 1:]

    # A `case X:  // why` line with the body below: the comment is the
    # head's, not a statement.
    head_comment = ""
    if not any(k and not c.isspace() for c, k in zip(inline.s, inline.m)):
        head_comment = inline.s.rstrip()
        inline = Line("", [])

    out = []
    for s in statements(inline.strip()):
        out.append(indent + unit + s.s)

    lines = rest.split("\n")
    while lines and not lines[0].strip():
        lines.pop(0)
    while lines and not lines[-1].strip():
        lines.pop()
    if lines:
        live = [ln for ln in lines if ln.strip()]
        have = min(len(ln) - len(ln.lstrip()) for ln in live)
        want = len(indent + unit)
        if "\t" not in "".join(ln[:have] for ln in live) and have != want:
            shift = want - have
            lines = [(" " * shift + ln if shift > 0 else ln[-shift:]) if ln.strip() else ""
                     for ln in lines]
        out.extend(ln.rstrip() for ln in lines)
    return head_comment, out


def convert_body(src, mask, arm, is_last, path, report):
    """(head comment, body lines) for a converted colon arm; raises Skip on
    fallthrough."""
    lo, hi = arm["head"] + 1, arm["end"]
    brk = trailing_break(src, mask, lo, hi)
    terminated = brk is not None

    # Work on a copy with the break cut out, so everything below sees the
    # body the match arm will actually have.
    if brk:
        src = src[:brk[0]] + " " * (brk[1] - brk[0]) + src[brk[1]:]
        mask = mask[:brk[0]] + [False] * (brk[1] - brk[0]) + mask[brk[1]:]

    # `case X: { ... }` -- the braces were only there for scoping.
    f = lo
    while f < hi and ((not mask[f]) or src[f].isspace()):
        f += 1
    if f < hi and src[f] == "{" and match_close(src, mask, f) + 1 == last_code(src, mask, lo, hi):
        lo, hi = f + 1, match_close(src, mask, f)

    for b in stray_breaks(src, mask, lo, hi):
        report.append(f"{path}:{line_of(src, b)}: `break` inside a case arm now "
                      "targets the enclosing loop, not the switch")

    if not terminated and not is_last:
        code = "".join(c if k else " " for c, k in zip(src[lo:hi], mask[lo:hi]))
        stmts = statements(Line(code, [True] * len(code)).strip())
        if not stmts or not TERMINATORS.match(stmts[-1].s):
            raise Skip(f"case at line {arm['line']} falls through into the next arm")

    return body_lines(src, mask, lo, hi, line_indent(src, arm["start"]), "    ")


def rewrite_arms(src, mask, lo, hi, path, report):
    """New text for the switch body [lo, hi), or None when unchanged."""
    arms = parse_arms(src, mask, lo, hi)
    if not arms:
        return None

    # Group into units: stacked empty labels + the arm they fall into.
    units, pending = [], []
    for a in arms:
        if a["form"] == "colon" and a["empty"]:
            pending.append(a)
            continue
        units.append((pending, a))
        pending = []
    if pending:
        units.append((pending, None))

    touched = [bool(p) or (a is not None and a["form"] == "colon") for p, a in units]
    if not any(touched):
        for a in arms:
            if a["form"] == "brace":
                for b in stray_breaks(src, mask, a["head"] + 1, a["end"] - 1):
                    report.append(f"{path}:{line_of(src, b)}: `break` inside a match "
                                  "arm targets the enclosing loop")
        return None

    out = [src[lo:units[0][0][0]["start"] if units[0][0] else units[0][1]["start"]]]
    prev_open = False   # previous unit ended with an arm we closed ourselves

    for ui, (labels, arm) in enumerate(units):
        first = labels[0] if labels else arm
        start = first["start"]
        if ui > 0:
            prev = units[ui - 1]
            prev_end = prev[1]["end"] if prev[1] else prev[0][-1]["end"]
            gap = src[prev_end:start]
            chain = touched[ui] and prev_open and not gap.strip() and gap.count("\n") <= 1
            if not gap.strip() and "\n" not in gap and touched[ui]:
                gap = "\n" + line_indent(src, start)
            if chain:
                gap = "\n" + line_indent(src, start)
            elif prev_open:
                out.append("\n" + line_indent(src, prev_end) + "}")
            out.append(gap)
        else:
            chain = False

        if not touched[ui]:
            out.append(src[arm["start"]:arm["end"]])
            prev_open = False
            continue

        indent = line_indent(src, start)
        lead = "} " if chain else ""
        is_default = (arm is not None and arm["kind"] == "default") or \
                     any(l["kind"] == "default" for l in labels)
        cases = [l for l in labels if l["kind"] == "case"]

        if is_default:
            if cases or (arm is not None and arm["kind"] == "case"):
                report.append(f"{path}:{first['line']}: case label(s) stacked on "
                              "`default` dropped -- default already catches them")
            head = [lead + "default {"]
        else:
            # One pattern line per source line of labels.
            # A label's trailing comment keeps its padding: `case X:` and
            # `X,` under a `case ` indent are the same width, so aligned
            # comments stay aligned.
            pats = [(l["pattern"], l["line"],
                     src[l["head"] + 1:l["end"]].rstrip(), l) for l in labels]
            if arm is not None:
                pats.append((arm["pattern"], arm["line"], "", arm))
            groups = []
            for p in pats:
                if groups and groups[-1][-1][1] == p[1]:
                    groups[-1].append(p)
                else:
                    groups.append([p])
            prefix = lead + "case "
            cont = indent + " " * len(prefix)
            head = []
            for gi, g in enumerate(groups):
                if gi:
                    # Comment lines between two label lines survive; blank ones
                    # do not.
                    prev_label = groups[gi - 1][-1][3]
                    for ln in src[prev_label["end"]:g[0][3]["start"]].split("\n")[1:-1]:
                        if ln.strip():
                            head.append(cont + ln.strip())
                text = (prefix if gi == 0 else cont) + ", ".join(p[0] for p in g)
                comment = g[-1][2]
                last = gi == len(groups) - 1
                text += " {" if last else ","
                if comment.strip():
                    text += comment if comment[:1].isspace() else " " + comment
                head.append(text)

        if arm is None:
            out.append("\n".join(head) + "}" if head[-1].endswith("{") else "\n".join(head))
            prev_open = False
            continue
        if arm["form"] == "brace":
            last_head = head[-1]
            # Keep the arm's own `{ ... }` verbatim; only the head is rebuilt.
            brace_text = src[arm["head"]:arm["end"]]
            head[-1] = last_head[:last_head.rfind(" {")] + " " + brace_text \
                if " {" in last_head else last_head + " " + brace_text
            out.append("\n".join(head))
            prev_open = False
            continue

        comment, body = convert_body(src, mask, arm, ui == len(units) - 1, path, report)
        if comment.strip():
            head[-1] += comment if comment[:1].isspace() else " " + comment
        out.append("\n".join(head + body))
        prev_open = True

    if prev_open:
        out.append("\n" + indent + "}")
    last = units[-1]
    last_end = last[1]["end"] if last[1] else last[0][-1]["end"]
    out.append(src[last_end:hi])
    return "".join(out)


def rewrite(src, path, report):
    count = 0
    mask = full_mask(src)
    hits = stmt_keywords(src, mask)

    # Right to left: an inner switch is rewritten before the one around it,
    # and the outer's start offset never moves.
    for p, e, word in reversed(hits):
        changed = False
        try:
            lo, hi = block_of(src, mask, e)
            new = rewrite_arms(src, mask, lo + 1, hi, path, report)
            if new is not None:
                src = src[:lo + 1] + new + src[hi:]
                changed = True
        except Skip as ex:
            report.append(f"{path}:{line_of(src, p)}: {word} arms left alone: {ex}")
        if word == "switch":
            src = src[:p] + "match" + src[e:]
            changed = True
        if changed:
            count += 1
            mask = full_mask(src)
    return src, count


if __name__ == "__main__":
    sys.exit(run(rewrite, "switch -> match, colon case labels -> braced arms"))
