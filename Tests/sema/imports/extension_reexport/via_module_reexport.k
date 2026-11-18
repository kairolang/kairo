import lib
fn main() -> i32 {
    var q = lib::pt::Q { v: 1 }
    return q.shown() + q.hidden() + lib::tags::tag_of(q) + lib::tags::mark_of(q) - 15
}

// --- lit wiring -----------------------------------------------------------
// `import lib` reaches lib/module.k, whose exports are its `pub import`s.
// lib/pext.k is one, so its `shown` is visible here; lib/hidden.k is a
// `priv import` of the module.k, an implementation detail, so its `hidden`
// is not. The conformances follow the same rule: pext.k's `impl Tagged`
// satisfies tag_of's bound here, hidden.k's `impl Marked` cannot satisfy
// mark_of's. An import edge does not carry every extension.
//
// RUN: cd %S && { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK:     via_module_reexport.k:4:26: error [R025E]: no member named 'hidden' in 'Q'
// CHECK-NOT: 'shown'
// CHECK:     hidden.k:3:1: note [I900N]: an extension of 'Q' in 'hidden.k' declares 'hidden'; import it to use it
// CHECK:     via_module_reexport.k:4:60: error [SC162E]: 'Q' does not conform to 'Marked' here: 'mark' is implemented by an extension this file does not import
// CHECK-NOT: 'Tagged'
