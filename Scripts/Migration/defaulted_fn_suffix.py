#!/usr/bin/env python3
# A defaulted or deleted function says so after its signature, not before it:
#
#     default fn Foo(self);                  ->  fn Foo(self) = default
#     delete fn op = (self, o: ref!(Foo));   ->  fn op = (self, o: ref!(Foo)) = delete
#     override default fn op delete (self);  ->  override fn op delete (self) = default
#
# Any ctor, dtor or operator can take either form. Other modifiers keep their
# place; only the `default`/`delete` word moves. The trailing `;` goes with it
# -- the declaration is newline-terminated once the suffix is there.
#
# Sites already in the suffix form carry no prefix and are never matched. A
# site with BOTH (`default fn X(self) = default`) just loses the prefix; one
# whose prefix and suffix disagree is reported, not guessed at.
#
# The signature can span lines: its end is the first `;`, `{` or newline at
# bracket depth 0, so a parameter list broken across lines is one signature.
# A `{` there means the declaration has a body, which a defaulted/deleted
# function cannot -- reported rather than rewritten.
import sys, os, re
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kairo_lex import code_mask

# `default`/`delete`, any other modifiers on the same line, then `fn`. Horizontal
# whitespace only: `default` ending one line and `fn` starting the next is a
# match arm followed by a declaration, not a prefix.
PREFIXED = re.compile(r"\b(default|delete)[ \t]+((?:[A-Za-z_]\w*[ \t]+)*?)fn\b")
SUFFIX = re.compile(r"=\s*(default|delete)\s*$")


def sig_stop(src, mask, i):
    """First `;`, `{` or newline at bracket depth 0 from i, or len(src).

    Not kairo_lex.scan_to: that counts `{` as an opener before it looks at the
    stop set, so a body would be swallowed as part of the signature.
    """
    depth = 0
    n = len(src)
    while i < n:
        c = src[i]
        if mask[i]:
            if depth == 0 and c in ";{\n":
                return i
            if c in "([{":
                depth += 1
            elif c in ")]}":
                if depth == 0:
                    return i
                depth -= 1
        i += 1
    return n


def rewrite(src, path, report):
    mask = code_mask(src)
    hits = [m for m in PREFIXED.finditer(src)
            if all(mask[k] for k in range(m.start(), m.end()))]
    count = 0

    # Right to left, so an edit never shifts the offsets of a later one.
    for m in reversed(hits):
        kind = m.group(1)
        end = sig_stop(src, mask, m.end())
        line = src.count("\n", 0, m.start()) + 1

        if end < len(src) and src[end] == "{":
            report.append(f"{path}:{line}: `{kind} fn` has a body")
            continue

        # Last code byte of the signature. Walking back over non-code as well
        # as whitespace keeps a trailing `// comment` AFTER the inserted
        # suffix: without a `;`, the stop is the newline that ends the comment.
        k = end - 1
        while k >= m.end() and ((not mask[k]) or src[k].isspace()):
            k -= 1
        sig_end = k + 1
        sig = src[m.end():sig_end]

        existing = SUFFIX.search(sig)
        if existing and existing.group(1) != kind:
            report.append(f"{path}:{line}: `{kind} fn` already ends `= {existing.group(1)}`")
            continue

        tail = src[sig_end:end]
        rest = src[end + 1:] if end < len(src) and src[end] == ";" else src[end:]
        suffix = "" if existing else f" = {kind}"

        src = (src[:m.start()] + m.group(2) + "fn" + sig + suffix
               + tail + rest)
        count += 1

    return src, count


if __name__ == "__main__":
    from kairo_lex import run
    sys.exit(run(rewrite, "defaulted/deleted fn: `default fn X(...);` -> `fn X(...) = default`"))
