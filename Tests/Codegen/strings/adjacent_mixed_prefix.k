// Adjacent string literals join whatever their prefixes. Each segment
// is lexed under its own prefix (a raw one keeps its backslashes, a plain one
// decodes its escapes, an f one has holes), and the whole is one string:
// with any f segment it is an f-string whose holes are every segment's, in
// source order, exactly as if `+` joined the segments; without one it stays
// a compile-time literal (so an `eval` may hold it, which an f-string may
// not, SC116E). Only an unprefixed continuation would otherwise chain, and a
// prefixed one was a new statement whose value was discarded.

import std::io

fn tick(c: *i32, d: i32) -> i32 {
    (*c) = (*c) * 10 + d
    return d
}

eval LIT: string = "plain\x41" r"\raw\n" "\x42"

fn main() -> i32 {
    var x = 7
    var y = "why"
    var c: i32 = 0

    io::println("a" f"b{x}")
    io::println(f"a{x}" f"b{y}")
    io::println("p\\n" r"r\n" "\x41")
    io::println("[" f"{x:>3}" r"\t" f"{tick(&c, 1)}" "|" f"{tick(&c, 2)}" "]")
    io::println(r"raw\" f"\t{x=}" "\x42")
    io::println("split"
        f" {x}"
        rf" \{y}\")
    io::println("""tri""" f"{x}" """ple""")
    io::println(f"{x}" "{y}")
    io::println(LIT)
    io::println(f"in {f"{x}" r"\z" f"{y}"} out")

    var s = "a" f"{x}"
    var t = "a" + f"{x}"
    io::println(f"{s == t} {c}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT --match-full-lines
// OUT:      ab7
// OUT-NEXT: a7bwhy
// OUT-NEXT: p\nr\nA
// OUT-NEXT: [  7\t1|2]
// OUT-NEXT: raw\	x=7B
// OUT-NEXT: split 7 \why\
// OUT-NEXT: tri7ple
// OUT-NEXT: 7{y}
// OUT-NEXT: plainA\raw\nB
// OUT-NEXT: in 7\zwhy out
// OUT-NEXT: true 12
