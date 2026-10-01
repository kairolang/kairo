// sequence.k -- exit 1
struct C { var n: i32; }

extend C {
    fn add(self, x: i32) -> i32 { self.n += x; return self.n; }
}

fn make(trace: *i32, v: i32) -> C { *trace = *trace * 10 + 1; return C { n: v }; }
fn arg(trace: *i32, v: i32) -> i32 { *trace = *trace * 10 + 2; return v; }

fn main() -> i32 {
    var trace: i32 = 0;
    var r = make(&trace, 3).add(arg(&trace, 4));
    if (trace == 12) && (r == 7) { return 1; }
    return 0;
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// Receiver before argument: `make` runs first (trace 12, not 21). The
// receiver is bound by value and passed by address.
// CXX: int main() {
// CXX: ::sequence::C __kairo_arg{{[0-9]+}} = ::sequence::make((& trace), 3);
// CXX-NEXT: signed int __kairo_arg{{[0-9]+}} = ::sequence::arg((& trace), 4);
// CXX-NEXT: __kairo_ext_C::add((& __kairo_arg{{[0-9]+}}), __kairo_arg{{[0-9]+}});

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -c --cache-dir %t.d
// RUN: %clangxx %t.d/*.o %t.d/builtin/*.o %t.d/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 1
