#!/usr/bin/env python3
# Visibility leads the modifier run of a function:
#
#     inline pub fn ig_kind(self)      ->  pub inline fn ig_kind(self)
#     inline static priv fn f()        ->  priv inline static fn f()
#
# Only the visibility word (pub / priv / prot) moves; every other modifier
# keeps its relative order, and the whitespace between words stays where it
# was, so a column-aligned run stays aligned.
#
# A run that repeats a modifier (`inline inline priv fn`) or names two
# visibilities is reported, not rewritten -- which copy was meant is a
# by-hand call, and silently deduping would hide it.
import sys, os, re
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kairo_lex import masked_hits, run

VIS = ("pub", "priv", "prot")
MODS = ("pub|priv|prot|inline|static|eval|const|virtual|override|unsafe|"
        "friend|default|delete|async|extern")

# A run of two or more modifiers on one line, ending at `fn`. Horizontal
# whitespace only: a modifier cannot sit on the line before its `fn`.
RUN = rf"\b(?:(?:{MODS})[ \t]+){{2,}}(?=fn\b)"
WORD = re.compile(r"\S+")


def rewrite(src, path, report):
    count = 0
    for m in reversed(masked_hits(src, RUN)):
        text = m.group()
        words = WORD.findall(text)
        vis = [w for w in words if w in VIS]
        if not vis or words[0] in VIS:
            continue
        line = src.count("\n", 0, m.start()) + 1
        if len(vis) > 1 or len(set(words)) != len(words):
            report.append(f"{path}:{line}: `{' '.join(words)} fn` repeats a modifier")
            continue

        # Separators between the words, including the one before `fn`, stay
        # in position; only the words are reordered into them.
        seps = re.split(r"\S+", text)[1:]
        reordered = vis + [w for w in words if w not in VIS]
        new = "".join(w + s for w, s in zip(reordered, seps))
        src = src[:m.start()] + new + src[m.end():]
        count += 1
    return src, count


if __name__ == "__main__":
    sys.exit(run(rewrite, "visibility first: `inline pub fn` -> `pub inline fn`"))
