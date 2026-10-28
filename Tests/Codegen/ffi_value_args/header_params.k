// Value arguments of an imported class template, one per parameter shape in
// vargs.h. Each instance is filled from clang (ForeignInstantiate), which
// needs the argument spelled back as a C++ template argument of the
// parameter's own type (TypeExport::to_clang_arg): before, every one of
// these failed to fill and member lookup fell back to the pattern.

ffi "c++" import "vargs.h"

fn main() -> i32 {
    var t: Flag<true>
    var f: Flag<false>
    var p: Paint<2>                  // an enum parameter takes the integer
    var n: Neg<-3>
    var w: Narrow<255>               // clang prints it '\xff'; must stay 255
    var c: Const<i32, 42>            // the parameter's type is T
    var b: Buf<i32>                  // N defaulted: Buf<i32, 3>
    var b5: Buf<i32, 5>
    b5.at(4) = 7
    var h: Holder<i32>
    h.get().at(1) = 9                // Buf<i32, 2> reached through Holder
    var r = t.get() + f.get()                          // 30
    r += p.code() + n.get() + w.width() + c.get()      // 200 - 3 + 255 + 42 = 494
    r += (b.cap() as i32) + (b5.cap() as i32) + b5.at(4) + h.get().at(1)   // 3 + 5 + 7 + 9 = 24
    return r - 500                                     // 548 - 500 = 48
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 48
