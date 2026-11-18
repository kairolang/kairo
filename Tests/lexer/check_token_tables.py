#!/usr/bin/env python3
# Checks that the hand-written tables in Compiler/Token/TokenKind.k agree with
# the TokenKind enum. The enum cannot be iterated (its values are spelling
# hashes) and it is @open, so no match on it has to be exhaustive: a kind
# missing from a table compiles and misbehaves at run time instead.
#
#   1. is_valid_token_kind, token_kind_to_string and
#      token_kind_to_readable_string name every enumerator, once. The lexer
#      accepts a word or operator only when is_valid_token_kind holds for its
#      hash.
#   2. No two kinds share a name or a spelling.
#   3. word_token_kinds lists every kind whose spelling is a word, in the
#      enum's order (the language server's keyword completion reads it).
#   4. The class predicates partition the kinds by their prefix: Kw* are
#      is_keyword, At* is_annotation, Bi* is_builtin, Tk* is_special, Lit*
#      is_literal, apart from the named exceptions below.
#   5. No match in TokenKind.k or TokenText.k lists a kind twice, and every
#      kind a table names is an enumerator.
#
#     python3 check_token_tables.py <Compiler/Token> <Scripts>
#
# Exit status 0 when all agree; 1 with one line per disagreement otherwise.
import os
import re
import sys
from collections import Counter

# Kw* kinds that are not is_keyword, and the predicate that holds instead.
KW_NOT_KEYWORD = {
    "KwSelf": "is_special",   # the receiver, a special identifier
    "KwTrue": "is_literal",
    "KwFalse": "is_literal",
    "KwIn": "is_binary_operator",
}
# Kinds a class predicate holds for besides its own prefix.
CLASS_EXTRA = {
    "is_special": {"AtComment", "KwSelf"},
    "is_literal": {"KwTrue", "KwFalse"},
}
# The word operators (`and`, `bitor`, ...): substitute() replaces each with
# its operator kind at lex time, so no later stage sees one.
WORD_OPERATORS = "is_substitutable"


def fn_body(src, name):
    i = src.index("pub fn %s(" % name)
    j = src.index("\n}\n", i)
    return src[i:j]


def kinds_in(body):
    return re.findall(r"TokenKind::(\w+)", body)


def match_arms(body):
    """Each top-level `match` in body, as the list of kinds its arms name."""
    out = []
    for m in re.finditer(r"\bmatch\b[^{]*\{", body):
        depth, i, arms = 1, m.end(), []
        while depth and i < len(body):
            c = body[i]
            if c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
            i += 1
        seg = body[m.end():i]
        for cm in re.finditer(r"\bcase\s+((?:TokenKind::\w+[\s,]*)+)\{", seg):
            arms += re.findall(r"TokenKind::(\w+)", cm.group(1))
        out.append(arms)
    return out


def main(argv):
    token_dir, scripts = argv[1], argv[2]
    sys.path.insert(0, scripts)
    from check_token_hashes import enum_members, spelling_table  # noqa: E402

    src = open(os.path.join(token_dir, "TokenKind.k"), encoding="utf-8").read()
    text = open(os.path.join(token_dir, "TokenText.k"), encoding="utf-8").read()
    members = enum_members(src)
    names = [n for n, _ in members]
    value = dict(members)
    errors = []

    for v, n in Counter(value.values()).items():
        if n > 1:
            errors.append("value %d is shared by %s" % (v, [k for k in names if value[k] == v]))

    def table(fn, every=True):
        listed = kinds_in(fn_body(src, fn))
        for k, n in Counter(listed).items():
            if n > 1:
                errors.append("%s: %s listed %d times" % (fn, k, n))
            if k not in value:
                errors.append("%s: %s is not a TokenKind" % (fn, k))
        if every:
            for k in names:
                if k not in listed:
                    errors.append("%s: no row for %s" % (fn, k))
        return set(listed)

    # 1, 2
    table("is_valid_token_kind")
    table("token_kind_to_string")
    table("token_kind_to_readable_string")
    to_string = dict(re.findall(r'case TokenKind::(\w+) \{\s*return "((?:[^"\\]|\\.)*)"',
                                fn_body(src, "token_kind_to_string")))
    for label, rows in (("token_kind_to_string", to_string),
                        ("token_kind_to_readable_string", spelling_table(src))):
        for s, n in Counter(rows.values()).items():
            if n > 1:
                errors.append("%s: %r is used by %s" % (label, s, sorted(k for k in rows if rows[k] == s)))

    # 3
    readable = spelling_table(src)
    words = [k for k in names
             if value[k] > 0xFF and re.fullmatch(r"[A-Za-z_]\w*!?", readable.get(k, ""))]
    listed = kinds_in(fn_body(src, "word_token_kinds"))
    for k in words:
        if k not in listed:
            errors.append("word_token_kinds: no row for %s" % k)
    for k in listed:
        if k not in words:
            errors.append("word_token_kinds: %s is not a word kind" % k)
    if [k for k in listed if k in words] != [k for k in words if k in listed]:
        errors.append("word_token_kinds: not in the enum's order")

    # 4
    preds = {p: table(p, every=False) for p in
             ("is_keyword", "is_annotation", "is_builtin", "is_special", "is_internal",
              "is_literal", "is_binary_operator", WORD_OPERATORS)}
    prefix = {"Kw": "is_keyword", "At": "is_annotation", "Bi": "is_builtin",
              "Tk": "is_special", "Lit": "is_literal"}
    for k in names:
        m = re.match(r"(Kw|At|Bi|Tk|Lit)", k)
        if not m:
            continue  # Op*: the operator predicates, not a class
        pre = m.group(1)
        want = prefix[pre]
        if k in KW_NOT_KEYWORD:
            want = KW_NOT_KEYWORD[k]
        elif pre == "Kw" and k in preds[WORD_OPERATORS]:
            want = WORD_OPERATORS
        if k not in preds[want]:
            errors.append("%s: %s is not in it" % (want, k))
        for p in ("is_keyword", "is_annotation", "is_builtin", "is_special", "is_literal"):
            if p != want and k in preds[p] and k not in CLASS_EXTRA.get(p, ()):
                errors.append("%s: holds for %s, which is %s" % (p, k, want))
    for k in preds["is_internal"] - preds["is_special"]:
        errors.append("is_internal: holds for %s, which is not is_special" % k)

    # 5
    for label, s in (("TokenKind.k", src), ("TokenText.k", text)):
        for fn in re.finditer(r"fn (\w+)\(", s):
            end = s.find("\n    }\n", fn.end()) if label == "TokenText.k" else s.find("\n}\n", fn.end())
            for arms in match_arms(s[fn.end():end]):
                for k, n in Counter(arms).items():
                    if n > 1:
                        errors.append("%s %s: case %s appears %d times" % (label, fn.group(1), k, n))
                    if k not in value:
                        errors.append("%s %s: %s is not a TokenKind" % (label, fn.group(1), k))

    for e in errors:
        print("error: " + e)
    print("%d kinds, %d word kinds, %d disagreements" % (len(names), len(words), len(errors)))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
