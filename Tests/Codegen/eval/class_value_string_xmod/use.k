import lib::*

// EVAL.md §11 / §12: `Widget<SMALL>` is `Widget<Config(4, "small")>` when
// SMALL is that constructor call over those literals -- also when SMALL is
// another module's, whose initializer is already lowered (the string a
// `string(bytes, len, cp)` construction, the call naming the constructor):
// the lowered forms give the written forms' nodes.

fn main() -> i32 {
    var a = Widget<SMALL>()
    var b: Widget<Config(4, "small")> = a        // one type across modules
    return b.size()
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR-LABEL: CODEGEN C++: {{.*}}use.k
// IR:      ::lib::Widget< ::lib::Config(4, ::builtin::string::string( ::__kairo_estr<115, 109, 97, 108, 108>, 5, 5))> a =
// IR:      ::lib::Widget< ::lib::Config(4, ::builtin::string::string( ::__kairo_estr<115, 109, 97, 108, 108>, 5, 5))> b = a;

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 4
