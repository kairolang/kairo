// A C++ function template called on a dependent value keeps its result out
// of the callee's parameter names for more call shapes: the moved value used
// directly as the return expression, passed on to another function, and the
// same body instantiated for a second type. No `_Tp` is emitted and each
// instance runs correctly.

ffi "c++" import "utility"

fn <T> id(x: T) -> T { return x }

class <T> Box {
    pub var p: unsafe *T

    pub fn direct(self) -> T {
        var unsafe *slot = self.p
        return cxx::std::move(*slot)
    }

    pub fn chained(self) -> T {
        var unsafe *slot = self.p
        return id(cxx::std::move(*slot))
    }
}

fn main() -> i32 {
    var x: i32 = 7
    var y: i64 = 30
    var a: Box<i32>
    var b: Box<i64>
    a.p = unsafe &x
    b.p = unsafe &y
    return a.direct() + a.chained() + (b.direct() as i32) + (b.chained() as i32) - 74
}

// --- lit wiring ---
// RUN: rm -f %t.exe && rm -rf %t.d
// RUN: %kairo %s --print-ir --cache-dir %t.d 2>&1 | %FileCheck %s --check-prefix=IR
// IR-NOT: _Tp>
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 0
