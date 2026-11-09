// `*D? -> *B?` (derived to base) and `*B? -> *const B?` (adding const)
// keep the null and convert the pointer: a return, an argument, an
// initializer and an explicit `as` all build and run. Nullable has
// no converting constructor in C++, so these were a static_cast clang
// rejected (CL001E "no matching conversion").

class B { var x: i32 = 1 }
class D derives B { var y: i32 = 2 }

fn up(d: *D?) -> *B? { return d }
fn takec(p: *const B?) -> i32 {
    if p? { return p->x }
    return 0
}
fn viac(p: *B?) -> i32 { return takec(p) }

fn main() -> i32 {
    var d = D()
    d.x = 5
    var *pb? = up(&d)
    var none: *D? = &null
    var r = viac(pb)                    // 5
    if !up(none)? { r += 10 }           // 15
    var pc: *const B? = pb
    if pc? { r += pc->x * 100 }         // 515
    var *pe? = none as *B?
    if !pe? { r += 1000 }               // 1515
    return r % 256                      // 235
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 235
