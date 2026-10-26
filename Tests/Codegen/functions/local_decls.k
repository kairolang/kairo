// Functions, classes and enums declared inside a function body (functions-
// declarations.mdx; classes.mdx): each is visible from its declaration to the
// end of the block.
//
// XFAIL: *
// Ticket "[Codegen] Functions, classes and enums declared in a function body
// are not emitted" (private/IMPORTANT/TICKETS.TXT, 2026-10-26). Today each
// type-checks and ICEs: "EmitIR: statement-scope named decls (local
// fn/class/type) are not emitted yet". A local `struct` works. When it
// XPASSes, delete the XFAIL -- the run below is already the real assertion.

fn main() -> i32 {
    fn helper(x: i32) -> i32 { return x + 1 }
    class P {
        pub var x: i32 = 2
    }
    enum Color { Red, Green }
    var p = P()
    var c = Color::Green
    var r = helper(4) + p.x                     // 5 + 2
    if c == Color::Green { r += 10 }
    return r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 17
