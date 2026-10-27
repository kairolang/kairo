// CRTP, duck-typed: `class <X: type> Mixin` defers every access to X until
// instantiation (the C++ rule, Tests/Sema/ExprTyper/bounds.k), so the base
// calls into the derived class with no bound at all. crtp_bounded.k is the
// bounded spelling.
//
// `: type` is the transitional C++-checked regime behind -fduck-generics
// (MONO.md D1): Sema leaves `d->value()` unbound on purpose, EmitIR spells
// the call as written, and clang resolves it in each instance. It used to
// ICE there ("EmitIR: unbound callee reached codegen"). Without the flag
// the same file is an error at each `: type` (duck_generics_gate.k).
//
// The safe `&self as *const X` is still refused under `: type` (SC091E,
// nothing relates X to Self), so the pointer is reinterpreted.

class <X: type> Mixin {
    fn doubled(const self) -> i32 {
        unsafe {
            var d = &self as unsafe *const X
            return d->value() * 2
        }
    }
}

class Seven derives Mixin<Seven> {
    fn value(const self) -> i32 { return 7 }
}

class Five derives Mixin<Five> {
    fn value(const self) -> i32 { return 5 }
}

fn <T: type> plain(t: T) -> i32 { return t.value() }    // the non-CRTP case

fn main() -> i32 {
    var s = Seven()
    var f = Five()
    return s.doubled() + f.doubled() + plain(Five())    // 14 + 10 + 5
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s -fduck-generics --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -fduck-generics -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 29
