// CRTP, duck-typed: `class <X: type> Mixin` defers every access to X until
// instantiation (the C++ rule, Tests/Sema/ExprTyper/bounds.k), so the base
// calls into the derived class with no bound at all. This is the usual
// way to write CRTP here; crtp_bounded.k is the bounded spelling.
//
// The safe `&self as *const X` is still refused under `: type` (SC091E,
// nothing relates X to Self), so the pointer is reinterpreted.
//
// XFAIL: *
// Waiting on codegen emitting a DEPENDENT call: Sema leaves `d->value()`
// unbound on purpose, and EmitIR::_call ICEs on any unbound callee
// ("EmitIR: unbound callee reached codegen; ExprTyper gate failure"). It
// must spell the call textually and let clang resolve it per instance.
// Not CRTP-specific: `fn <T: type> f(t: T) -> i32 { return t.value() }`
// ICEs the same way, by value, through *T and through unsafe *T.
//
// When it lands this test XPASSes; delete the XFAIL -- the run below is
// already the real assertion.

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
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 29
