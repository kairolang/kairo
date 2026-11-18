// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 71
//
// `cxx::std::move(x)` returns `remove_reference_t<T>&&`, which imports as a
// C++ rvalue reference to an OPAQUE alias. Kairo's deduction substitutes T
// but leaves the opaque referee alone, so the call typed as `<ffi type>&&`
// and `self.f = cxx::std::move(other.f)` failed with SC028E "cannot convert
// '<ffi type>&&' to 'SF<64>'". A return type that merely CONTAINS an opaque
// type takes clang's substituted one, as a wholly opaque one already
// did.

// DIAG-NOT: error

ffi "c++" import "move_opaque_return.h"
ffi "c++" import "utility"

class Task {
    pub var f: SF<64>
    pub var p: Plain
    fn Task(self) {}
    @move fn Task(self, other: Self) {
        self.f = cxx::std::move(other.f)
        self.p = cxx::std::move(other.p)
    }
}

fn main() -> i32 {
    var a: Task
    a.p.x = 7
    var b = Task(cxx::std::move(a))
    return b.f.v + b.p.x
}
