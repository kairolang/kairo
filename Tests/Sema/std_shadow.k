// rule: the bare-`std` alias is an ordinary overlay binding, so a TU that
// declares its own `module std { }` shadows it by the normal rule -- the DC
// chain is searched before the import overlay. No special case in lookup, and
// no diagnostic: this is what shadowing an imported name has always done.
//
// The return type is the assertion. `kairo::std::print` returns void; this one
// returns i32 and is used as an i32, so if the alias won instead of the local
// module, this file is a type error rather than a silently-wrong binding.

module std {
    fn print(value: i32) -> i32 { return value }
}

fn use_own() -> i32 {
    return std::print(7)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}} [
