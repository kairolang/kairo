// The setter `m[k] = v` and the place form `m[k] += 1` copy the key on a
// miss (hash_map.k: "Both write forms copy `k` only on a miss"). For a key
// whose only copy is its own `copy()` method (it declares `impl Copyable`,
// and a move constructor, no copy constructor) the copy helper traps
// instead of calling `copy()`, so the first insert through either form
// aborts. `insert` is unaffected.
//
// Cases from libc++ test/std/containers/unord/unord.map/unord.map.elem/index.pass.cpp

import std::io

var copies: u64 = 0

class MKey {
    pub var v: u64
    pub fn MKey(self, v: u64) { self.v = v }
    @move pub fn MKey(self, other: Self) { self.v = other.v }
}

extend MKey impl Hash {
    fn hash(const self, @inout h: Hasher) { h.write_u64(self.v) }
    fn op == (const self, const o: MKey) -> bool { return self.v == o.v }
}

extend MKey impl Copyable {
    fn copy(const self) -> MKey {
        copies += 1
        return MKey(self.v)
    }
}

fn main() -> i32 {
    var m: {MKey: u64}
    var k = MKey(1)
    m[k] = 10
    if m.size() != 1 || m[MKey(1)] != 10 { return 1 }
    if copies != 1 { return 2 }
    m[k] = 11
    if copies != 1 || m[MKey(1)] != 11 { return 3 }
    m[k] += 5
    if m[MKey(1)] != 16 || copies != 1 { return 4 }
    var n = MKey(2)
    m[n] += 7
    if m[MKey(2)] != 7 || copies != 2 { return 5 }
    io::println("done")
    return 0
}

// --- lit wiring ---
// RUN: rm -f %t.exe %t.o2.exe
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe | %FileCheck %s
// CHECK: done
