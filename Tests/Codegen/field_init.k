// A field's initializer is its default, and C++ runs it in every constructor
// that does not initialize the field itself: the implicit one, a declaration
// with no initializer, a user constructor that leaves the field alone, a
// struct literal that omits it. A defaulted copy does not run it again, and
// a user constructor that assigns the field is what the field holds after.
// A constant is spelled in the class as it is; every other default is the
// body of a member function the class's default calls: an ADT variant spelled
// out, written `.V` and built with a payload, a string, a call of a function
// declared after the class, and two impure arguments SequenceLowering orders
// in a statement expression, which only a function body can hold.

var calls: i32 = 0

enum <T> Slot { One { v: T }, Empty }

fn tick(n: i32) -> i32 { calls = calls + 1; return n }
fn add(a: i32, b: i32) -> i32 { return a * 10 + b }

class A {
    pub var x: i32 = 5
    pub var p: unsafe *void = &null
    pub var s: Slot<i32> = Slot<i32>::Empty
    pub var t: Slot<i32> = .Empty
    pub var u: Slot<i32> = Slot<i32>::One { v: 3 }
    pub var str: string = "hi"
    pub var c: i32 = seven()
    pub var d: i32 = add(tick(1), tick(2))
}

fn seven() -> i32 { return 7 }

// The constructor sets y and leaves x to its default.
class B {
    pub var x: i32 = 5
    pub var y: i32 = 6
    pub fn B(self, y: i32) { self.y = y }
}

// A default reads an earlier member of its record: it keeps the type body's
// scope, and C++ reads the member through the thunk's `this`.
class R {
    pub var a: i32 = 4
    pub var b: i32 = a + 1
}

// With its default, a const field no longer leaves the default constructor
// deleted.
class K {
    pub const k: i32 = 3
}

struct S {
    var a: i32 = 11
    var b: i32
}

class <T> G {
    pub var v: T = T()
    pub var n: i32 = 9
}

fn payload(s: Slot<i32>) -> i32 = match s {
    case .One(var v) => v
    default          => -1
}

fn chk(c: bool) -> i32 { if c { return 1 } return 0 }

fn main() -> i32 {
    var a = A()
    var n = chk(a.x == 5)
    n += chk(a.p == &null)
    n += chk(payload(a.s) == -1)
    n += chk(payload(a.t) == -1)
    n += chk(payload(a.u) == 3)
    n += chk(a.str.len == 2)
    n += chk(a.c == 7)
    n += chk((a.d == 12) && (calls == 2))    // tick(1) before tick(2)

    var e: A                                 // no initializer: the defaults still run
    n += chk((e.x == 5) && (calls == 4))

    a.x = 8
    var f = a                                // a defaulted copy: no default runs
    n += chk((f.x == 8) && (calls == 4))

    var b = B(1)
    n += chk((b.x == 5) && (b.y == 1))

    var r = R()
    n += chk((r.a == 4) && (r.b == 5))

    var k = K()
    n += chk(k.k == 3)

    var s = S { b: 2 }
    n += chk((s.a == 11) && (s.b == 2))

    var g = G<i32>()
    n += chk((g.v == 0) && (g.n == 9))
    return n
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// A constant in the class as it is; anything else a call of the member that
// holds it, declared with the methods.
// RUN: { %kairo %s --type-check-only --print-cxx 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// A comes last: it holds a string, so it follows string's definition.
// CXX:      class R {
// CXX:      signed int a = 4;
// CXX-NEXT: signed int b = __kairo_init_b();
// CXX:      class K {
// CXX:      const signed int k = 3;
// CXX:      struct S {
// CXX:      signed int a = 11;
// CXX-NEXT: signed int b;
// CXX:      template<class T> class G {
// CXX:      T v = __kairo_init_v();
// CXX-NEXT: signed int n = 9;
// CXX:      T __kairo_init_v();
// CXX:      class A {
// CXX:      signed int x = 5;
// CXX-NEXT: void{{ ?}}* p = nullptr;
// CXX-NEXT: ::field_init::Slot<signed int> s = __kairo_init_s();
// CXX:      signed int d = __kairo_init_d();
// CXX:      ::field_init::Slot<signed int> __kairo_init_s();

// The expression is the member's body, out of line; the statement
// expression that orders tick(1) before tick(2) is in it.
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR-LABEL: CODEGEN C++: {{.*}}field_init.k
// IR:      A::__kairo_init_c() {
// IR-NEXT: return{{ ?}}::field_init::seven();
// IR:      signed int A::__kairo_init_d() {
// IR:      __kairo_arg
// IR:      template<class T> T G<T>::__kairo_init_v() {

// REQUIRES: clang
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s -c --cache-dir %t.d/k
// RUN: %clangxx %t.d/k/*.o %t.d/k/builtin/*.o %t.d/k/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 15
