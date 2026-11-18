// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 12
//
// A C++ container element is a `u32&`, and as an operand it is the u32 it
// refers to: `v[0] - 1` is u32 arithmetic with the literal taking u32, and
// `v[i] as i64` casts the u32. The literal was handed the reference as its
// expected type and stayed i32 (SC033E "operands 'u32' and 'i32' do not
// unify"), and `as` found no conversion from 'u32&' (SC027E).

ffi "c++" import "vector"

class M {
    priv var _s: cxx::std::vector<u32>
    fn M(self) {
        self._s.push_back(5)
        self._s.push_back(7)
    }
    fn d(self, i: usize, kb: u32) -> i64 {
        var x = self._s[0] - 1
        return (self._s[i] as i64) - (kb as i64) + (x as i64)
    }
}

fn main() -> i32 {
    var m = M()
    // d: 7 - 3 + (5 - 1) = 8; 8 + 4 = 12
    return (m.d(1, 3) as i32) + 4
}

// DIAG-NOT: error
