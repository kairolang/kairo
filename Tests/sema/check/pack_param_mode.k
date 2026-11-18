fn <...T> bump(@inout ...args: T) { }
fn <...T> take(@move ...args: T) { }
fn <...T> plain(...args: T) { }
fn main() -> i32 {
    var a = 1
    var b = 2
    bump(&a, &b)
    plain(a, b)
    return 0
}

// --- lit wiring -----------------------------------------------------------
// A passing mode on a pack parameter is an error for now, at the mode.
// It was silently dropped: `bump(&a, &b)` deduced T = *i32 and every layer
// below passed the pointers by value. The call itself reports nothing more.
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not=error
// CHECK: pack_param_mode.k:1:16: error [SC204E]: '@inout' on pack parameter 'args' is not supported yet: a passing mode on a pack has no meaning for its elements
// CHECK: pack_param_mode.k:2:16: error [SC204E]: '@move' on pack parameter 'args' is not supported yet: a passing mode on a pack has no meaning for its elements
