// `label!` / `jump!` names written in a macro body. JumpLabelCheck
// compares label names as identifiers, through the wrapper: a name from a
// macro body is a wrapped token whose imm is its own expansion record, so
// comparing imms would match no label (SC006E "target is not declared"
// beside its own `label!`), and a macro declaring one label twice would
// not be a duplicate. Type-checked only: label!
// and jump! are SC116E "not yet supported" past Sema.

macro retry!() {
    label!(again)
    n += 1
    if n < 3 {
        jump!(again)
    }
}

macro twice!() {
    label!(a)
    label!(a)
}

fn count() -> i32 {
    var n = 0
    retry!()
    return n
}

fn dup() {
    twice!()
}

fn main() -> i32 { return count() }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: label_in_macro.k:29:5: error [SC007E]: duplicate `label!` name in this function
