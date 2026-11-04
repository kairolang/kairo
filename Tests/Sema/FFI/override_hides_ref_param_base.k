// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty
//
// G88: a Kairo `override` of a C++ virtual whose parameter is a reference
// spells it as a mode (`const x: T` for `const T&`, `@inout` for `T&`,
// `@move` for `T&&`), while the imported parameter carries the reference in
// its TYPE. _same_signature compared the two as different, so the override
// never hid the base's virtual and `x.Begin(o, p)` on the derived type was
// SC064E between them (ClangDiagAdapter::BeginSourceFile).
// CHECK-NOT: error

ffi "c++" import "override_hides_ref_param_base.h"

class Mine derives ob::Consumer {
    override fn Begin(self, const o: ob::Opts, p: unsafe *const ob::Pre) {}
    override fn Fill(self, @inout out: ob::Opts, i: i32) {}
    override fn Take(self, @move o: ob::Opts) {}
}

fn use(m: *Mine, @inout o: ob::Opts) {
    m->Begin(o, &null)
    m->Fill(o, 1)
}
