// An imported C++ function template called with an argument of the
// enclosing generic's type (`*slot` on `slot: *T`) is not deduced
// until the instance: its declared return type is an opaque that spells the
// CALLEE's parameters (`__libcpp_remove_reference_t<_Tp>&&`), never the
// call's type. The local stays `auto` with no cast naming `_Tp`; before the
// fix the emitted C++ failed with "use of undeclared identifier '_Tp'"
// (Compiler/Memory/ArenaList.k has the same `cxx::std::move(*slot)`).

ffi "c++" import "utility"

class <T> Box {
    pub var p: unsafe *T
    pub var q: unsafe *T

    pub fn take(self) -> T {
        var unsafe *slot = self.p
        var val = cxx::std::move(*slot)
        return val
    }

    pub fn exchange(self) {
        cxx::std::swap(*self.p, *self.q)
    }
}

fn main() -> i32 {
    var x: i32 = 7
    var z: i32 = 30
    var b: Box<i32>
    b.p = unsafe &x
    b.q = unsafe &z
    b.exchange()
    // x is 30, z is 7: 30 + 7 + 5 = 42.
    return b.take() + z + 5
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s --print-ir --cache-dir %t.d 2>&1 | %FileCheck %s --check-prefix=IR
// IR-NOT: _Tp>
// IR: auto val = ::std::move(
// IR-NOT: _Tp>
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 42
