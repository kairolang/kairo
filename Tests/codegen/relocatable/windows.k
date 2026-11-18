// `@relocatable` on the Windows targets. Win64 returns a two-word record
// through memory whatever its attributes, so there is no register return
// to gain and none is promised; the record compiles without a diagnostic
// and is still relocatable to `__builtin_is_trivially_relocatable`, which
// stays false for a record with a destructor and no attribute.
//
// The Microsoft C++ ABI also passes a record with no copy constructor
// through memory, and clang would drop `trivial_abi` from every record
// holding a move-only relocatable one, warning each time. The attribute is
// not written for those targets; the MinGW targets follow the Itanium C++
// ABI and keep it.
//
// That ABI also has the callee destroy every by-value parameter, so a
// function that takes a value with a destructor runs that destructor and is
// not inferred `const` there, relocatable or not.

@relocatable
class Handle {
    pub var a: usize
    pub var b: usize

    pub fn Handle(self, a: usize) {
        self.a = a
        self.b = a
    }

    @move pub fn Handle(self, other: Self) {
        self.a  = other.a
        self.b  = other.b
        other.a = 0
    }

    pub fn op finally(self) {}
}

@relocatable
class <T> Box {
    pub var p: *T?
    pub var n: usize

    pub fn Box(self, n: usize) {
        self.p = null
        self.n = n
    }

    @move pub fn Box(self, other: Self) {
        self.p  = other.p
        self.n  = other.n
        other.n = 0
    }

    pub fn op finally(self) {}
}

@relocatable
class Outer {
    pub var h: Handle
    pub var b: Box<i32>

    pub fn Outer(self, a: usize) {
        self.h = Handle(a)
        self.b = Box<i32>(a)
    }

    @move pub fn Outer(self, other: Self) = default
    pub fn op finally(self) {}
}

class Owned {
    pub var a: usize

    pub fn Owned(self, a: usize) {
        self.a = a
    }

    @move pub fn Owned(self, other: Self) {
        self.a  = other.a
        other.a = 0
    }

    pub fn op finally(self) {}
}

@no_inline fn peek_owned(o: Owned) -> usize { return o.a }
@no_inline fn take_plain(h: Handle) -> usize { return h.a }
@no_inline fn make_plain(a: usize) -> Handle { return Handle(a) }
@no_inline fn take_nested(o: Outer) -> usize { return o.h.a + o.b.n }
@no_inline fn make_nested(a: usize) -> Outer { return Outer(a) }

@no_inline fn relocatable_plain() -> bool { return __builtin_is_trivially_relocatable<Handle>() }
@no_inline fn relocatable_generic() -> bool { return __builtin_is_trivially_relocatable<Box<i32>>() }
@no_inline fn relocatable_nested() -> bool { return __builtin_is_trivially_relocatable<Outer>() }
@no_inline fn relocatable_owned() -> bool { return __builtin_is_trivially_relocatable<Owned>() }

fn main() -> i32 {
    var got = take_plain(make_plain(7)) + take_nested(make_nested(3)) + peek_owned(Owned(1))
    if got != 14 || !relocatable_plain() || !relocatable_generic() || !relocatable_nested() || relocatable_owned() {
        return 1
    }

    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang, sysroot-x86_64-windows-gnu
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s --emit=llvm-ir -O1 --target=x86_64-windows-gnu --cache-dir %t.d/ir 2>&1 | %FileCheck %s --check-prefix=QUIET --allow-empty
// RUN: %FileCheck %s --check-prefix=IR < %t.d/ir/windows.ll
// RUN: %kairo %s --print-ir --target=x86_64-windows-gnu | %FileCheck %s --check-prefix=CXX
// CXX: class __attribute((trivial_abi)) Handle {
// CXX-NEXT: public: using __kairo_relocatable = Handle;
// CXX: __attribute((noinline)) __attribute((const)) decltype(sizeof(0)) peek_owned(
// CXX: __attribute((noinline)) decltype(sizeof(0)) take_plain(

// QUIET-NOT: error [
// QUIET-NOT: warning [

// IR-DAG: define {{.*}}void @{{.*}}make_plain{{.*}}(ptr {{.*}}sret({{.*}}Handle{{.*}}) {{.*}}, i64 noundef %{{[^,)]*}})
// IR-DAG: define {{.*}}void @{{.*}}make_nested{{.*}}(ptr {{.*}}sret({{.*}}Outer{{.*}}) {{.*}}, i64 noundef %{{[^,)]*}})
// IR: define {{.*}}i1 @{{.*}}relocatable_plain{{.*}}()
// IR: ret i1 true
// IR: define {{.*}}i1 @{{.*}}relocatable_generic{{.*}}()
// IR: ret i1 true
// IR: define {{.*}}i1 @{{.*}}relocatable_nested{{.*}}()
// IR: ret i1 true
// IR: define {{.*}}i1 @{{.*}}relocatable_owned{{.*}}()
// IR: ret i1 false
