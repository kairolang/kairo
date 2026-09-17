#!/usr/bin/env python3
# Foo::<T> -> Foo<T>.
#
# v0.1.0 removed turbofish; `<` is the only generic-argument syntax. The
# sequence `::<` appears nowhere else in the language, so this is a literal
# replacement -- but still masked, since `::<` occurs inside string literals
# (diagnostic text, test fixtures) that must not be rewritten.
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kairo_lex import masked_hits, run


def rewrite(src, path, report):
    hits = masked_hits(src, r"::<")
    for m in reversed(hits):
        src = src[: m.start()] + "<" + src[m.end():]
    return src, len(hits)


if __name__ == "__main__":
    sys.exit(run(rewrite, "turbofish removal: Foo::<T> -> Foo<T>"))
