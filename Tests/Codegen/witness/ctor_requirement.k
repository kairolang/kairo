// witness/ctor_requirement.k -- exit 169
// CONSTRUCTOR requirements (CODEGEN.md §7b.3): `T(args)` in a bounded body
// is plain C++ construction, so no witness member exists for one -- not
// in the primary, not in a specialization -- and the concept lists it as
// `__kairo_Self(a0, ...)` (forwarded), so a host's class without the constructor
// fails at the call. A composed interface carries its base's clause. `T()`
// on a bound that promises it is typed as T, so `t.show()` binds. A
// generic interface's parameter in the requirement is the concept's own.
pub interface Defaultable { fn Defaultable(self) }
pub interface Sized { fn Sized(self, n: i32) }
pub interface Show { fn show(const self) -> i32 }
pub interface Both derives Defaultable + Show { }
pub interface Twin { fn Twin(self, other: Self, k: i32) }
pub interface <T> Cloneable { fn Cloneable(self, source: T) }

pub class Counter {
    pub var n: i32 = 0
    fn Counter(self) { }
    fn Counter(self, n: i32) { self.n = n }
    fn Counter(self, other: Counter, k: i32) { self.n = other.n + k }
}
extend Counter {
    pub fn show(const self) -> i32 = self.n + 100
}
pub struct Plain { pub var n: i32 = 7 }
pub class <E> Box {
    pub var n: i32 = 0
    fn Box(self, e: E) { self.n = 40 }
}

pub fn <T impl Defaultable> fresh(like: T) -> T { return T() }
pub fn <T impl Sized> sized(like: T, n: i32) -> T { return T(n) }
pub fn <T impl Both> both(like: T) -> i32 { var t = T(); return t.show() }
pub fn <T impl Twin> twin(a: T) -> T { return T(a, 5) }
pub fn <C impl Cloneable<i32>> clone_from(like: C, v: i32) -> C { return C(v) }

fn main() -> i32 {
    var a = fresh(Counter(1))
    var b = sized(Counter(), 3)
    var p = fresh(Plain())
    var q = sized(Box<i32>(1), 9)
    var t = twin(b)
    // 0 + 3 + 7 + 40 + 100 + 8 + 11
    return a.n + b.n + p.n + q.n + both(a) + t.n + clone_from(a, 11).n
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// Both's specialization exists for its extension `show` alone.
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: CODEGEN C++: {{.*}}witness/ctor_requirement.k
// CXX: concept Defaultable_c = requires {
// CXX-NEXT: __kairo_Self();
// CXX-NEXT: };
// CXX: concept Sized_c = requires(signed int __kairo_a0) {
// CXX-NEXT: __kairo_Self(static_cast<decltype(__kairo_a0) &&>(__kairo_a0));
// CXX-NEXT: };
// CXX: concept Both_c = requires(const __kairo_Self * __kairo_r1) {
// CXX-NEXT: __kairo_Self();
// CXX-NEXT: Both_witness<__kairo_Self>::show(__kairo_r1);
// CXX-NEXT: };
// CXX: concept Twin_c = requires(__kairo_Self __kairo_a0, signed int __kairo_a1) {
// CXX-NEXT: __kairo_Self(static_cast<decltype(__kairo_a0) &&>(__kairo_a0), static_cast<decltype(__kairo_a1) &&>(__kairo_a1));
// CXX-NEXT: };
// CXX: concept Cloneable_c = requires(T __kairo_a0) {
// CXX-NEXT: __kairo_Self(static_cast<decltype(__kairo_a0) &&>(__kairo_a0));
// CXX-NEXT: };
// CXX: struct Defaultable_witness {
// CXX-NEXT: };
// CXX: struct Sized_witness {
// CXX-NEXT: };
// CXX: struct Both_witness {
// CXX-NEXT: static signed int show(
// CXX: struct Twin_witness {
// CXX-NEXT: };
// CXX-NOT: template<> struct {{(Defaultable|Sized|Twin)}}_witness
// CXX: template<> struct Both_witness<{{ ?}}::{{.*}}::Counter> {
// CXX-NEXT: static signed int show(
// CXX-NEXT: return{{ ?}}::{{.*}}::__kairo_ext_Counter::show(self);
// CXX-NEXT: }
// CXX-NEXT: };
// CXX: return T();
// CXX: return T(n);
// CXX: T t = T();
// CXX: return T(a, 5);

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 169
