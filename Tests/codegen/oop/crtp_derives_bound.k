// The CRTP declaration shape: a generic base bounded by `derives` on its
// own instance (`class <X derives Mixin<X>> Mixin`) and a class deriving
// the instance named after itself. The bound is checked against a class
// that is still being declared, and the base's own members reach the
// derived object.
//
// What this does NOT cover is the base calling INTO X, which is the point
// of CRTP: that needs a bound granting X's members, and that form fails in
// clang today -- see crtp_bounded.k.

class <X derives Mixin<X>> Mixin {
    fn tag(const self) -> i32 { return 40 }
}

class Seven derives Mixin<Seven> {
    fn seven(const self) -> i32 { return 7 }
}

fn main() -> i32 {
    var r = 0
    var s = Seven()
    if s.tag() == 40 { r += 1 }
    if s.seven() == 7 { r += 2 }
    var m: *Mixin<Seven> = &s
    if m->tag() == 40 { r += 4 }
    return r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 7
