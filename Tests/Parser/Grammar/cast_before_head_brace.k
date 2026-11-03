// P349: a cast directly before the `{` that ends a head. The cast parser
// rolls `as T` back when a `{` follows the type, since at statement level
// that brace is a context binding's body (`open(p) as const f { ... }`). In
// an if / while / for / match head no binding can appear and the brace is
// the body, so the rollback left `as` dangling: S056E "expected '{' after
// 'if' condition", S052E "expected expression, found 'as'". Self-host site:
// Compiler/Memory/MMapRegion.k (`if mapping == MAP_FAILED as unsafe *u8 {`).

fn heads(m: unsafe *u8, x: unsafe *u8, n: u8) -> i32 {
    var r = 0
    if m == x as unsafe *u8 {
        r = 1
    }
    if r == n as i32 {
        r = 2
    }
    while r == n as i32 {
        r = r + 1
    }
    return r
}

// --- lit wiring ---

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:11:13: warning [SC031W]: redundant cast: 'unsafe *u8' converts to 'unsafe *u8' implicitly
// END-GENERATED-CHECKS(DIAG)
