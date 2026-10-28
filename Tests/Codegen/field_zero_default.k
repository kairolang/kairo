// A field with no initializer whose type has a default is zero-initialized
// in every constructor (variables.mdx: "Types with a default value are
// zero-initialized when declared without an initializer"). C++ leaves a
// scalar member default-initialized, i.e. indeterminate, in any constructor
// that does not name it: a user constructor with an empty body read stack
// garbage. Each such field now carries a `{}` default member initializer,
// so a user constructor, the implicit one, a split one (a const field) and
// a generic class's all read 0; a nested record without a constructor is
// zeroed through its own fields; a union's first member is zeroed. The
// probe fills the stack with non-zero bytes first, then builds each object
// in the frame it dirtied.

enum Color { Red, Green, Blue }

struct Inner { pub var a: i32  pub var b: u64 }

union Bits { pub var raw: u32  pub var lo: u16 }

class F {
    pub var n: i32
    pub var d: f64
    pub var p: *i32
    pub var c: Color
    pub var arr: [i16; 4]
    pub var u: u8
    pub var inner: Inner
    pub var bits: Bits
    pub var set: i32 = 9                 // an initializer is kept
    fn F(self) { }
}

class Split {
    pub const id: i32
    pub var left: i64
    fn Split(self, id: i32) { self.id = id }
}

class <T> W {
    pub var v: T
    pub var k: i32
    fn W(self) { }
}

struct Implicit { pub var x: i32  pub var y: f32 }

fn smash(k: i32) -> i32 {
    var a: [i32; 256]
    for var i = 0; i < 256; ++i { a[i] = k * 7919 + i * 31 + 1 }
    var s = 0
    for var i = 0; i < 256; ++i { s += a[i] & 1 }
    return s
}

fn probe() -> i32 {
    var f = F()
    var s = Split(5)
    var w = W<i64>()
    var m = Implicit()
    var r = 0
    if f.n != 0 { r += 1 }
    if f.d != 0.0 { r += 2 }
    if f.p != &null { r += 4 }
    if f.c != Color::Red { r += 8 }
    for var i = 0; i < 4; ++i { if f.arr[i] != 0 { r += 16 } }
    if f.u != 0 { r += 32 }
    if (f.inner.a != 0) || (f.inner.b != 0) { r += 64 }
    if f.bits.raw != 0 { r += 128 }
    if f.set != 9 { r += 256 }
    if (s.id != 5) || (s.left != 0) { r += 512 }
    if (w.v != 0) || (w.k != 0) { r += 1024 }
    if (m.x != 0) || (m.y != 0.0) { r += 2048 }
    return r
}

fn main() -> i32 {
    var t = smash(77)
    var r = probe()
    if t < 0 { return 99 }
    return r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR-LABEL: CODEGEN C++: {{.*}}field_zero_default.k
// IR:      struct Inner {
// IR-NEXT: signed int a {
// IR-NEXT: };
// IR-NEXT: unsigned long{{( long)?}} b {
// IR-NEXT: };
// A union's one initializer is its first member's.
// IR:      union Bits {
// IR-NEXT: unsigned int raw {
// IR-NEXT: };
// IR-NEXT: unsigned short lo;
// A record field is left to its own constructor; an initializer is kept.
// IR:      class F {
// IR-NEXT: public: signed int n {
// IR-NEXT: };
// IR-NEXT: double d {
// IR-NEXT: };
// IR-NEXT: signed int * p {
// IR-NEXT: };
// IR-NEXT: ::field_zero_default::Color c {
// IR-NEXT: };
// IR-NEXT: signed short arr[4] {
// IR-NEXT: };
// IR-NEXT: unsigned char u {
// IR-NEXT: };
// IR-NEXT: ::field_zero_default::Inner inner;
// IR-NEXT: ::field_zero_default::Bits bits {
// IR-NEXT: };
// IR-NEXT: signed int set = 9;
// A const field is the constructor's to build.
// IR:      class Split {
// IR-NEXT: public: const signed int id;
// IR-NEXT: signed long{{( long)?}} left {
// IR-NEXT: };
// IR:      template<class T> class W {
// IR-NEXT: public: T v {
// IR-NEXT: };

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 0
