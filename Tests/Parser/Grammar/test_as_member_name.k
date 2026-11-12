// `test` names a member. It is a keyword only to open a top-level test
// block (`test "name" { ... }`): after `fn` in a type body, after `Class::`
// in an out-of-line definition and after an access operator a test block
// cannot start, so there `test` is the identifier it spells, and a C++
// method named `test` (`std::bitset::test`) can be called. A top-level
// `fn test()` stays an error (Inputs/test_as_member_name/top_level_fn.k).

ffi "c++" import "bitset"

class Flags {
    var bits: u32 = 0
    fn set(self, i: u32) { self.bits = self.bits | (1 as u32 << i) }
    fn test(const self, i: u32) -> bool { return (self.bits & (1 as u32 << i)) != 0 }
    static fn test(a: i32, b: i32) -> i32 { return a + b }
}

class Probe {
    fn test(self) -> i32
}

fn Probe::test(self) -> i32 { return 7 }

fn main() -> i32 {
    var f = Flags()
    f.set(3)
    if !f.test(3) { return 1 }
    if f.test(2) { return 2 }
    var *p = &f
    if !p->test(3) { return 3 }
    if Flags::test(2, 3) != 5 { return 4 }
    var q = Probe()
    if q.test() != 7 { return 5 }

    var b: cxx::std::bitset<8>
    b.set(5)
    if !b.test(5) || b.test(4) { return 6 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty --implicit-check-not="error ["
// RUN: rm -rf %t.d && %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: { %kairo %S/Inputs/test_as_member_name/top_level_fn.k --syntax-only 2>&1 || true; } | %FileCheck %s --check-prefix=TOP --implicit-check-not="error ["
// TOP: top_level_fn.k:1:4: error [S047E]: unexpected 'test'
