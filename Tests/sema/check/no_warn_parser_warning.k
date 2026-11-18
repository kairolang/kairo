// `@no_warn(CODE)` drops the named warning wherever it is reported
// inside the declaration, by any stage (attributes.mdx). S055W (a nested
// nullable) is the parser's: it was reported, and drained, before Sema
// registered the scope, so the attribute had no effect on it. The parser
// applies the scope as soon as the declaration it is on is complete.
// Outside the declaration, and for a code it does not name, the warning
// stays.

@no_warn(S055W)
fn quiet(x: (i32?)?) -> i32 { return 0 }

fn loud(x: (i32?)?) -> i32 { return 0 }

class C {
    @no_warn("S055W")
    var a: (i32?)? = null

    @no_warn(SC031W)
    var b: (i32?)? = null
}

@no_warn(S055W)
class D {
    var c: (i32?)? = null
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="warning [S055W]"
// CHECK: no_warn_parser_warning.k:12:18: warning [S055W]: nested nullable
// CHECK: no_warn_parser_warning.k:19:18: warning [S055W]: nested nullable
