// The comparisons derived from a member `op <=>` are written into the C++
// class, so a C++ host finds them: C++20's own rewrite, `(a <=> b) < 0`,
// cannot compile against `Ordering` (a scoped enum), and C++ never derives
// `==` from a user `<=>`. Ver declares only `<=>`: all six are emitted.
// Part declares `<`, `==` and `!=` itself (each warned about, see
// Sema/Operators/spaceship_derived.k): those are its own, so only `<=` `>`
// `>=` are emitted. Kairo uses go through the same rewrite and the program
// below encodes every answer in the exit code.

class Ver {
    pub var v: i32
    fn Ver(self, v: i32) { self.v = v }
    pub fn op <=> (const self, other: Ver) -> Ordering {
        if self.v < other.v { return Ordering::Less }
        if self.v > other.v { return Ordering::Greater }
        return Ordering::Equal
    }
}

class Part {
    pub var v: i32
    fn Part(self, v: i32) { self.v = v }
    pub fn op <=> (const self, other: Part) -> Ordering {
        if self.v < other.v { return Ordering::Less }
        if self.v > other.v { return Ordering::Greater }
        return Ordering::Equal
    }
    // Deliberately disagrees with `<=>`: the declared one must win.
    pub fn op < (const self, other: Part) -> bool { return true }
    pub fn op == (const self, other: Part) -> bool { return false }
    pub fn op != (const self, other: Part) -> bool { return false }
}

fn bit(b: bool, n: i32) -> i32 {
    if b { return n }
    return 0
}

fn main() -> i32 {
    var a = Ver(1)
    var b = Ver(2)
    var c = Ver(1)
    var r = 0
    r += bit(a < b, 1)          // 1
    r += bit(b <= a, 2)         // 0
    r += bit(b > a, 4)          // 4
    r += bit(a >= c, 8)         // 8
    r += bit(a == c, 16)        // 16
    r += bit(a != b, 32)        // 32
    var p = Part(5)
    var q = Part(5)
    r += bit(p < q, 64)         // 64: Part's own `<`, not `<=>`
    r += bit(p == q, 128)       // 0:  Part's own `==`
    r += bit(p >= q, 256)       // 256: derived
    return r                    // 381; the exit status is 381 % 256 = 125
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --print-cxx 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: class Ver {
// CXX:       Ordering operator<=>({{.*}}Ver other) const;
// CXX-NEXT:  bool operator<({{.*}}Ver o) const {
// CXX-NEXT:  return static_cast<signed char>(this -> operator<=>(static_cast<decltype(o)&&>(o))){{ ?}}<{{ ?}}0;
// CXX:       bool operator<=({{.*}}Ver o) const {
// CXX-NEXT:  operator<=>({{.*}}<= 0;
// CXX:       bool operator>({{.*}}Ver o) const {
// CXX-NEXT:  operator<=>({{.*}}>{{ ?}}0;
// CXX:       bool operator>=({{.*}}Ver o) const {
// CXX-NEXT:  operator<=>({{.*}}>= 0;
// CXX:       bool operator==({{.*}}Ver o) const {
// CXX-NEXT:  operator<=>({{.*}}== 0;
// CXX:       bool operator!=({{.*}}Ver o) const {
// CXX-NEXT:  operator<=>({{.*}}!= 0;
// CXX-LABEL: class Part {
// CXX:       Ordering operator<=>({{.*}}Part other) const;
// CXX-NEXT:  bool operator<({{.*}}Part other) const;
// CXX-NEXT:  bool operator==({{.*}}Part other) const;
// CXX-NEXT:  bool operator!=({{.*}}Part other) const;
// CXX-NOT:   bool operator<({{.*}}Part o)
// CXX-NOT:   bool operator==({{.*}}Part o)
// CXX-NOT:   bool operator!=({{.*}}Part o)
// CXX:       bool operator<=({{.*}}Part o) const {
// CXX:       bool operator>({{.*}}Part o) const {
// CXX:       bool operator>=({{.*}}Part o) const {
// CXX-NOT:   bool operator{{.*}}(::{{.*}}Part o)
// CXX:       };

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 125
