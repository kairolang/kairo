// RUN: %kfmt --normalize-parens --stdout %s | diff -u %S/Expected/string_chains.k -
// RUN: %kfmt --normalize-parens --check %S/Expected/string_chains.k
//
// P486: adjacent literals join whatever their prefixes, so a chain can hold
// f, r and plain segments. The chain is one literal to the formatter: every
// segment kept as written, no prefix split from its quote, a glued prefix
// (`"a"f"b"`) left glued, and the bytes of a later segment's hole untouched.

fn w(x: i32, s: string) -> string {
    var a = "a" f"b{x}"
    var b = "a"f"b"
    var c = r"\a" "b"
    g(
        "one "
            f"two {(x + 1)}"
            r" \three",
        x,
    )

    return "p" f"{s}" + "x"
}
