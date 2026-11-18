// `\{` and `\}` outside an f-string are a warning (S022W) and nothing more:
// the literal stays, and the escape is the brace, in a string, a chain, a
// character literal and a match pattern alike.

import std::io

fn kind(const s: string) -> i32 {
    match s {
        case "\{\}" { return 1 }
        default { return 0 }
    }
}

fn main() -> i32 {
    var s = "a\{b\}c"
    var t = "\{" "x" "\}"
    var c = '\{'
    var d = '\}'
    io::println(s)
    io::println(t)
    io::println(f"{s.length()} {c == '{'} {d == '}'} {kind("{}")}")
    return 0
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error ["
// DIAG: {{.*}}:9:15: warning [S022W]: '\{' and '\}' escapes are only valid inside format strings (f"..."); remove the backslash or use an f-string prefix
// DIAG: {{.*}}:9:17: warning [S022W]:
// DIAG: {{.*}}:15:15: warning [S022W]:
// DIAG: {{.*}}:15:18: warning [S022W]:
// DIAG: {{.*}}:16:14: warning [S022W]:
// DIAG: {{.*}}:16:23: warning [S022W]:
// DIAG: {{.*}}:17:14: warning [S022W]:
// DIAG: {{.*}}:18:14: warning [S022W]:
//
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --check-prefix=BUILD --allow-empty
// BUILD-NOT: error
// BUILD-NOT: unknown escape
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT --match-full-lines
// OUT:      a{b}c
// OUT-NEXT: {x}
// OUT-NEXT: 5 true true 1
