// `\{` and `\}` outside an f-string are the brace with a warning, S022W, whose fix-it removes the backslash; inside an
// f-string they are silent.
// Rules asserted (website language/diagnostics.mdx, S022W: "The escape is the brace and the literal is kept; the fix-it
// removes the backslash"; language/primitives.mdx, Strings: `\{` `\}` in f-strings).
// Cases from Rust library/coretests/tests/fmt/mod.rs (escaping: `{{` and `}}`, which Kairo spells `\{` and `\}`)

fn plain() -> string {
    var a = "a\{b\}"
    var b = "x\}"
    return a
}

fn inside() -> string {
    var n = 1
    var c = f"a\{b\}{n}"
    var d = f"\}"
    return c
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | grep -c 'S022W' | %FileCheck %s --check-prefix=COUNT
// COUNT: 3
// CHECK:      :8:{{[0-9]+}}: warning [S022W]
// CHECK-NEXT: fix-it:"{{.*}}":{8:15-8:16}:""
// CHECK:      :8:{{[0-9]+}}: warning [S022W]
// CHECK-NEXT: fix-it:"{{.*}}":{8:18-8:19}:""
// CHECK:      :9:{{[0-9]+}}: warning [S022W]
// CHECK-NEXT: fix-it:"{{.*}}":{9:15-9:16}:""
