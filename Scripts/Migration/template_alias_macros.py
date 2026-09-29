#!/usr/bin/env python3
# Template-alias macros -> the template they name:
#
#     __inline_cpp("
#     #define RecursiveASTVisitor_MoveCheck RecursiveASTVisitor<MoveCheck>
#     ");
#     ... RecursiveASTVisitor_MoveCheck::traverse_function_decl(n);
#
# becomes
#
#     ... RecursiveASTVisitor<MoveCheck>::traverse_function_decl(n);
#
# Stage 0 could not spell `Base<T>::method` as a qualified call head, so each
# visitor/writer file aliased it through a per-file preprocessor macro. Stage 1
# parses the generic head directly. The #define block goes, and so does its
# #undef block where the file has one (some do, some do not).
#
# Only an object-like macro whose body is a single `Name<...>` is rewritten.
# Any other #define (function-like, or an expression body like
# `#define sink this->_cg->sink`) is reported and left alone -- it is not an
# alias, and textually substituting it would guess at meaning.
import re, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kairo_lex import masked_hits, run

# One __inline_cpp("...") statement holding exactly one directive line.
BLOCK = r'[ \t]*__inline_cpp\(\s*"\s*#\s*{kw}\s+{body}\s*"\s*\)\s*;?[ \t]*\n?'
DEFINE = re.compile(BLOCK.format(kw="define", body=r"(?P<name>[A-Za-z_]\w*)(?P<rest>[^\"]*?)"))
ALIAS  = re.compile(r"\s+(?P<tmpl>[A-Za-z_][\w:]*\s*<[^\"\n]*>)\s*$")


def _rewrite(src, path, report):
    count = 0
    for m in list(DEFINE.finditer(src)):
        name, rest = m.group("name"), m.group("rest")
        a = ALIAS.fullmatch(rest)
        if rest.startswith("(") or not a:
            line = src.count("\n", 0, m.start()) + 1
            report.append(f"{path}:{line}: not a template alias  --  #define {name}{rest.rstrip()}")
            continue
        tmpl = re.sub(r"\s+", " ", a.group("tmpl").strip())

        # Drop the #define and any matching #undef block.
        src = src.replace(m.group(0), "", 1)
        undef = re.compile(BLOCK.format(kw="undef", body=re.escape(name)))
        src = undef.sub("", src)

        # Replace uses in code only -- a comment naming the macro keeps it.
        hits = masked_hits(src, rf"\b{re.escape(name)}\b")
        for h in reversed(hits):
            src = src[: h.start()] + tmpl + src[h.end():]
        count += 1 + len(hits)
    return src, count


def rewrite(src, path, report):
    return _rewrite(src, path, report)


SELFTEST = [
    ('__inline_cpp("\n#define RAV_M RAV<M>\n");\nfn f() { RAV_M::go(n); }\n',
     'fn f() { RAV<M>::go(n); }\n'),
    ('__inline_cpp("\n#define W_F W<F>\n");\nW_F::a();\n// W_F stays\n__inline_cpp("\n#undef W_F\n");\n',
     'W<F>::a();\n// W_F stays\n'),
    ('__inline_cpp("\n#define sink this->_cg->sink\n");\nsink.x();\n',
     '__inline_cpp("\n#define sink this->_cg->sink\n");\nsink.x();\n'),
    ('__inline_cpp("\n    #define A_bit(T, x) A<T>::_bit(x)\n");\n',
     '__inline_cpp("\n    #define A_bit(T, x) A<T>::_bit(x)\n");\n'),
    ('__inline_cpp("\n#define X_Y X<Y>\n");\nvar s = "X_Y";\nX_YZ();\n',
     'var s = "X_Y";\nX_YZ();\n'),
]


def selftest():
    bad = 0
    for src, want in SELFTEST:
        got, _ = _rewrite(src, "selftest", [])
        ok = got == want
        bad += 0 if ok else 1
        print(("ok   " if ok else "FAIL ") + repr(src) + ("" if ok else f"\n       want {want!r}\n       got  {got!r}"))
    print(f"\n{len(SELFTEST) - bad}/{len(SELFTEST)} passed")
    return 1 if bad else 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    sys.exit(run(rewrite, "template-alias macros: `#define B_T B<T>` -> B<T> at every use, directives removed"))
