// The C++ a by-value parameter of a destructive class is written as
// (Compiler/Spec/Ownership.md, by-value parameters): `C&&` in every
// declaration and in a `fn` type, `::__kairo_param<T>` where the type is
// the parameter of the extension that declares the function, and by value
// where it is the function's own type parameter (C++ deduces that one from
// the argument) or the function is declared in a generic record's body.
// A body that moves the parameter on at every exit is written as it was;
// one that does so on some paths has a guard whose flag each move clears.
// A caller hands a local or a parameter over as it is and builds any
// other value in `::__kairo_pass<C>` when the callee ends the object, and
// passes an object of the call's own (`static_cast<C>`) when it does not.
class C {
    var id: i32 = 0
    fn C(self, id: i32) { self.id = id }
    @move fn C(self, other: Self) { self.id = other.id }
    fn op finally(self) { }
}

fn reads(c: C) -> i32 { return c.id }
fn moves(c: C) -> C { return c }
fn passes(c: C) -> i32 { return reads(c) }
fn forwards(c: C) -> C { return moves(c) }
fn sometimes(c: C, yes: bool) -> i32 {
    if yes { return reads(c) }
    return 0
}

class <T> Stack {
    var items: [T]
    fn Stack(self, first: T) { self.items = []; self.items.push(first) }
    fn put(self, v: T) { self.items.push(v) }
}

extend <T> Stack<T> {
    fn add(self, v: T) { self.items.push(v) }
}

fn <T> own(x: T) -> T { return x }

fn caller(pick: bool) {
    var a = C(1)
    reads(a)
    var b = C(2)
    var c = moves(b)
    var d = moves(C(3))
    var e = C(4)
    var f = C(5)
    var g = moves(if (pick) => e else => f)
    var call: fn(C) -> i32 = reads
    call(C(6))
    var s = Stack<C>(C(7))
    s.put(C(8))
    s.add(C(10))
    var h = own<C>(C(9))
}

fn main() -> i32 { caller(true); return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// The helpers every signature and argument below names.
// CXX: template{{ ?}}<class T{{ ?}}>{{ ?}}using __kairo_param{{ ?}}=
// CXX: template{{ ?}}<class T{{ ?}}>{{ ?}}using __kairo_pass{{ ?}}=
// CXX: template{{ ?}}<class T{{ ?}}>{{ ?}}struct __kairo_pc {
// CXX-LABEL: CODEGEN C++: {{.*}}value_param_shapes.k
// A reader may be `pure`, never `const`: it reads the caller's object.
// CXX: __attribute((pure)) signed int reads({{.*}}C{{ ?}}&&{{ ?}}c) noexcept;
// CXX: {{.*}}C moves({{.*}}C{{ ?}}&&{{ ?}}c) noexcept;
// CXX: template{{ ?}}<class T{{ ?}}>{{ ?}}T own(T x) noexcept;
// Its own callee only reads, so `passes` gives it an object of the call's.
// CXX: signed int passes({{.*}}C{{ ?}}&&{{ ?}}c) noexcept {
// CXX-NEXT: return{{.*}}reads(static_cast<{{.*}}C{{ ?}}>(static_cast<{{.*}}C{{ ?}}&&>(c)));
// `moves` ends the object, so `forwards` hands the same storage on.
// CXX: {{.*}}C forwards({{.*}}C{{ ?}}&&{{ ?}}c) noexcept {
// CXX-NEXT: return{{.*}}moves(static_cast<{{.*}}C{{ ?}}&&>(c));
// CXX: signed int sometimes({{.*}}C{{ ?}}&&{{ ?}}c, bool yes) noexcept {
// CXX-NEXT: ::__kairo_pc<{{.*}}C{{ ?}}> __k_g_c {
// CXX-NEXT: __builtin_addressof(c), true
// CXX: reads(static_cast<{{.*}}C{{ ?}}>((__k_g_c.live = false, static_cast<{{.*}}C{{ ?}}&&>(c))));
// A member a generic record declares in its body keeps its parameter by
// value; an extension's member has the conditional type.
// CXX: inline Stack<T>::Stack(T first) noexcept {
// CXX: inline void Stack<T>::put(T v) noexcept {
// CXX: inline void __kairo_ext_Stack::add({{.*}}Stack<T>{{ ?}}*{{ ?}}self, ::__kairo_param<T> v) noexcept {
// CXX: inline T own(T x) noexcept {
// CXX: void caller(bool pick) noexcept {
// CXX: reads(static_cast<{{.*}}C{{ ?}}>(static_cast<{{.*}}C{{ ?}}&&>(__k_s_a.v)));
// CXX: C c ={{.*}}moves(static_cast<{{.*}}C{{ ?}}&&>(__k_s_b.v));
// CXX: C d ={{.*}}moves({{ ?}}::__kairo_pass<{{.*}}C{{ ?}}>({{.*}}C(3)));
// CXX: C g ={{.*}}moves({{ ?}}::__kairo_pass<{{.*}}C{{ ?}}>((pick ?(__k_s_e.live = false,
// CXX: ::__kairo_fn<signed int({{.*}}C{{ ?}}&&)> call =
// CXX-NEXT: call({{.*}}C(6));
// CXX: s.put({{.*}}C(8));
// CXX: __kairo_ext_Stack::add<{{.*}}C{{ ?}}>((& s), ::__kairo_pass<{{.*}}C{{ ?}}>({{.*}}C(10)));
// CXX: C h ={{.*}}own<{{.*}}C{{ ?}}>({{.*}}C(9));

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: rm -f %t.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
