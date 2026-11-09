// A `requires` on a member of a generic record is the member's C++20
// trailing requires-clause, on the in-class declaration and the out-of-line
// definition alike. As a static_assert in the body it failed at the
// record's explicit instantiation (`template class Box<Tracked>;`, which
// instantiates every member body) for every argument the predicate
// rejects, called or not. Box<Tracked> below never calls get(), so it must
// build and run.

class <T> Box {
    var ptr: unsafe *u8
    fn Box(self, p: unsafe *u8) { self.ptr = p }
    fn get(self) -> *T
      requires __builtin_is_trivially_copyable<T>() && __builtin_is_trivially_destructible<T>() {
        unsafe { return self.ptr as unsafe *T as *T }
    }
    fn small(self) -> usize requires sizeof T <= 64 { return sizeof T }
}

class Tracked {
    var v: i32
    fn Tracked(self) { self.v = 1 }
    @copy fn Tracked(self, other: Self) = delete
    fn op finally(self) { self.v = 0 }
}

fn main() -> i32 {
    var x: i32 = 5
    var p: unsafe *u8
    unsafe { p = &x as unsafe *u8 }
    var b = Box<i32>(p)
    var bt = Box<Tracked>(p)
    if b.small() != 4 { return 1 }
    return *b.get() - 5
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: CODEGEN C++: {{.*}}member_requires.k
// CXX:       template<class T> class Box {
// CXX:       T * get() noexcept requires(( ::kairo_rt_is_trivially_copyable<T>()) &&( ::kairo_rt_is_trivially_destructible<T>()));
// CXX-NEXT:  small() noexcept requires(((sizeof(T)) <=(64)));
// CXX:       Box<T>::get() noexcept requires(( ::kairo_rt_is_trivially_copyable<T>()) &&( ::kairo_rt_is_trivially_destructible<T>())) {
// CXX-NOT:   static_assert
// CXX:       Box<T>::small() noexcept requires(((sizeof(T)) <=(64))) {
// CXX-NOT:   static_assert
// CXX:       template class{{.*}}Box< ::member_requires::Tracked>;

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d/run
// RUN: %t.exe
