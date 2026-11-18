// Passing `*p` to a `@move` parameter moves the pointee: the call compiles
// to an rvalue-reference binding (`static_cast<Res &&>`): without the cast
// clang rejects binding the lvalue `*p` to the `Res &&` parameter. A read of
// the pointee afterwards is the use-after-move error SC052E.

class Res {
    pub var id: i32 = 0
    fn Res(self) { self.id = 0 }
    fn Res(self, id: i32) { self.id = id }
    @move fn Res(self, other: Self) {
        self.id = other.id
        other.id = 0
    }
}

var g_seen: i32 = 0

fn eat(@move r: Res) { g_seen = r.id }

fn through(p: *Res) { eat(*p) }

fn main() -> i32 {
    var a = Res(5)
    through(&a)
    if g_seen != 5 { return 1 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -f %t.exe
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}
// RUN: rm -rf %t.d
// RUN: %kairo %s -O0 -o %t.exe --cache-dir %t.d/o0
// RUN: %t.exe; test $? -eq 0
// RUN: rm -f %t.exe
// RUN: %kairo %s -O2 -o %t.exe --cache-dir %t.d/o2
// RUN: %t.exe; test $? -eq 0
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: eat(static_cast< ::{{.*}}Res &&>((* p)));
