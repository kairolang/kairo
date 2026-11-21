// `::__kairo_dm<T>` is the emitted C++'s copy of Sema's answer to "need a
// moved-from object of this type not be destroyed" (ClassLifecycle's
// `destructive`): false by default, true beside each class Sema says yes
// for. A generic class whose answer is each instance's computes it in a
// static member, and every instance this TU names pins Sema's answer with a
// static_assert, so a disagreement does not compile.
ffi "c++" import "dm_trait.hh"
import std::io::println

var n: i32 = 0

// MOVE, a destructor, every field trivial: yes.
class D {
    var id: i32 = 0
    fn D(self, id: i32) { self.id = id }
    @move fn D(self, other: Self) { self.id = other.id }
    fn op finally(self) { n += 1 }
}

// COPY: its move is a copy, the source stays whole. No.
class K {
    var id: i32 = 0
    fn K(self, id: i32) { self.id = id }
    @copy fn K(self, const other: Self) { self.id = other.id }
    fn op finally(self) { n += 1 }
}

// Holds a C++ type with a destructor: its moved-from field keeps C++'s
// rule. No.
class HoldCxx {
    var x: DmTraitCxx
    fn HoldCxx(self) { }
    @move fn HoldCxx(self, other: Self) = default
    fn op finally(self) { n += 1 }
}

// Generic, the answer fixed by the pattern: a pointer field.
class <T> Owner {
    var p: *T? = &null
    fn Owner(self) { }
    @move fn Owner(self, other: Self) { self.p = other.p }
    fn op finally(self) { n += 1 }
}

// Generic, the answer the instance's: it holds a T by value.
class <T> Box {
    var v: T
    fn Box(self, x: T) { self.v = x }
}

// A nullable holds its value by value and destroys it: a moved-from `K?`
// still holds a whole K. No, and no for a generic one over `T?` either.
class HoldOpt {
    var k: K? = null
    fn HoldOpt(self) { }
    @move fn HoldOpt(self, other: Self) = default
    fn op finally(self) { n += 1 }
}

class <T> Maybe {
    var v: T? = null
    fn Maybe(self) { }
    @move fn Maybe(self, other: Self) = default
    fn op finally(self) { n += 1 }
}

enum Color { Red, Green }

fn main() -> i32 {
    var a = Box<D>(D(1))
    var b = Box<i32>(2)
    var c = Box<K>(K(3))
    var o = Owner<D>()
    var h = HoldCxx()
    var t = (D(4), 5)
    var e = Color::Green
    var q = HoldOpt()
    var m = Maybe<D>()
    var mk = Maybe<K>()
    println(f"{a.v.id} {b.v} {c.v.id} {t.1}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: template{{ ?}}<class T{{ ?}}>{{ ?}}inline constexpr bool __kairo_dm{{ ?}}={{ ?}}false;
// CXX-DAG: template{{ ?}}<{{ ?}}>{{ ?}}inline constexpr bool __kairo_dm<{{ ?}}::dm_trait::D{{ ?}}>{{ ?}}={{ ?}}true;
// CXX-DAG: template{{ ?}}<class T{{ ?}}>{{ ?}}inline constexpr bool __kairo_dm<{{ ?}}::dm_trait::Owner<T{{ ?}}>{{ ?}}>{{ ?}}={{ ?}}true;
// CXX-DAG: static constexpr bool __kairo_dm_() noexcept {
// CXX-DAG: template{{ ?}}<class T{{ ?}}>{{ ?}}inline constexpr bool __kairo_dm<{{ ?}}::dm_trait::Box<T{{ ?}}>{{ ?}}>{{ ?}}={{ ?}}::dm_trait::Box<T{{ ?}}>::__kairo_dm_();
// CXX-DAG: static_assert({{ ?}}::__kairo_dm<{{ ?}}::dm_trait::Box<{{ ?}}::dm_trait::D{{ ?}}>{{ ?}}>{{ ?}}=={{ ?}}true,
// CXX-DAG: static_assert({{ ?}}::__kairo_dm<{{ ?}}::dm_trait::Box<signed int{{ ?}}>{{ ?}}>{{ ?}}=={{ ?}}false,
// CXX-DAG: static_assert({{ ?}}::__kairo_dm<{{ ?}}::dm_trait::Box<{{ ?}}::dm_trait::K{{ ?}}>{{ ?}}>{{ ?}}=={{ ?}}false,
// CXX-DAG: static_assert({{ ?}}::__kairo_dm<{{ ?}}::dm_trait::Maybe<{{ ?}}::dm_trait::D{{ ?}}>{{ ?}}>{{ ?}}=={{ ?}}false,
// CXX-DAG: static_assert({{ ?}}::__kairo_dm<{{ ?}}::dm_trait::Maybe<{{ ?}}::dm_trait::K{{ ?}}>{{ ?}}>{{ ?}}=={{ ?}}false,

// No specialization for a COPY class, a class holding a C++ type with a
// destructor or a nullable, an enum or a tuple; no member in a class that
// has an answer of its own.
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=NOT
// NOT-LABEL: CODEGEN C++: {{.*}}dm_trait.k
// NOT: class D {
// NOT-NOT: __kairo_dm_
// NOT: };
// NOT-NOT: __kairo_dm<{{ ?}}::dm_trait::K{{ ?}}>{{ ?}}=
// NOT-NOT: __kairo_dm<{{ ?}}::dm_trait::HoldCxx{{ ?}}>
// NOT-NOT: __kairo_dm<{{ ?}}::dm_trait::HoldOpt{{ ?}}>
// NOT-NOT: __kairo_dm<{{ ?}}::dm_trait::Color
// NOT-NOT: __kairo_dm<{{ ?}}::builtin::Tuple

// Both static_asserts compile, and the program runs.
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: rm -f %t.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT --match-full-lines
// OUT: 1 2 3 5
