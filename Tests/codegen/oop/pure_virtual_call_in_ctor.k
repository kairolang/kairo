// Calling a pure virtual member from a constructor or destructor of its own
// class is undefined behavior; the compiler rejects it (C170) unless
// `-A C170W` allows it. A call to a virtual with a body is fine.

class Base {
    virtual fn f(self) -> i32

    fn Base(self) {
        self.f()
    }

    @copy fn Base(self, const other: Self) = delete
    fn op finally(self) { }
}

class D derives Base {
    override fn f(self) -> i32 { return 1 }
}

fn main() -> i32 {
    var d = D()
    return d.f()
}

// --- lit wiring -----------------------------------------------------------
// RUN: rm -f %t.exe %t2.exe
// RUN: { %kairo %s -o %t.exe 2>&1 || true; } | %FileCheck %s
// RUN: test ! -f %t.exe
// RUN: %kairo %s -A C170W -o %t2.exe
// CHECK: pure_virtual_call_in_ctor.k:9:{{[0-9]+}}: error [C170E]: call to pure virtual member function 'f'
