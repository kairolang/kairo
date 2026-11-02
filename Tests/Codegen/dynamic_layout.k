// `__builtin_dynamic_size<T>(p)` / `__builtin_dynamic_align<T>(p)`: the
// layout of the object p points at. For a T with a virtual destructor every
// class in the hierarchy carries a hidden virtual `__kairo_layout()`, so a
// `*Base` that holds a Derived answers for Derived: what a sized allocator
// must be given back when `destroy<Base>` frees it. For any other T it is
// T's own sizeof / alignof, with no call.

class Base {
    var a: i64
    fn Base(self) { self.a = 1 }
    @copy fn Base(self, other: Self) = delete
    virtual fn op delete(self) { }
}
class Derived derives Base {
    var b: [i64; 8]
    fn Derived(self) { self.a = 2 }
    @copy fn Derived(self, other: Self) = delete
    override fn op delete(self) { }
}
// No destructor of its own: it inherits Derived's virtual one, and its
// layout too must be its own.
class Deeper derives Derived {
    var c: [i64; 4]
    fn Deeper(self) { self.a = 3 }
    @copy fn Deeper(self, other: Self) = delete
}
class Plain {
    var x: i32
    fn Plain(self) { self.x = 3 }
}

// What a counting sized allocator would be handed by destroy<T>.
static freed_size: usize = 0
static freed_align: usize = 0

fn <T> sized_free(p: *T) {
    freed_size = __builtin_dynamic_size<T>(p)
    freed_align = __builtin_dynamic_align<T>(p)
}

fn main() -> i32 {
    var d = Derived()
    var *bp = &d as *Base
    sized_free<Base>(bp)
    if freed_size != sizeof Derived { return 1 }
    if freed_align != alignof Derived { return 2 }
    var e = Deeper()
    var *ep = &e as *Base
    sized_free<Base>(ep)
    if freed_size != sizeof Deeper { return 3 }
    var b = Base()
    sized_free<Base>(&b)
    if freed_size != sizeof Base { return 4 }
    var pl = Plain()
    sized_free<Plain>(&pl)
    if (freed_size != 4) || (freed_align != 4) { return 5 }
    var i: i64 = 0
    if __builtin_dynamic_size<i64>(&i) != 8 { return 6 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: CODEGEN C++: {{.*}}dynamic_layout.k
// CXX:       class Base {
// CXX:       virtual const decltype(sizeof(0)) * __kairo_layout() const noexcept {
// CXX:       class Derived:
// CXX:       virtual const decltype(sizeof(0)) * __kairo_layout() const noexcept override {
// CXX:       class Deeper:
// CXX:       virtual const decltype(sizeof(0)) * __kairo_layout() const noexcept override {
// CXX:       class Plain {
// CXX-NOT:   __kairo_layout
// CXX:       };

// The build must be warning-free: clang's -Winconsistent-missing-override
// fires on a hidden override that does not say so.
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: { %kairo %s -o %t.exe --cache-dir %t.d/run --error-format=basic 2>&1 || true; } | %FileCheck %s --check-prefix=BUILD --allow-empty
// BUILD-NOT: warning
// RUN: %t.exe
