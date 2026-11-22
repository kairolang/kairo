// A `@relocatable` record with a destructor and a `@move` constructor is
// passed and returned as a plain struct of its layout is: two words travel
// in two registers, with no hidden `sret` pointer for the result and no
// `byval` or indirect copy for the argument. The same holds for an instance
// of a generic record and for a record that holds a relocatable one by
// value. `Slow` is the same shape without the attribute and goes through
// memory both ways.

static live: i32 = 0

@relocatable
class Handle {
    pub var a: usize
    pub var b: usize

    pub fn Handle(self, a: usize) {
        self.a = a
        self.b = a
        live += 1
    }

    @move pub fn Handle(self, other: Self) {
        self.a  = other.a
        self.b  = other.b
        other.a = 0
    }

    pub fn op finally(self) {
        if self.a != 0 {
            live -= 1
        }
    }
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

    pub fn op finally(self) {
        self.n = 0
    }
}

@relocatable
class Outer {
    pub var h: Handle

    pub fn Outer(self, a: usize) {
        self.h = Handle(a)
    }

    @move pub fn Outer(self, other: Self) {
        self.h = other.h
    }

    pub fn op finally(self) {}
}

class Slow {
    pub var a: usize
    pub var b: usize

    pub fn Slow(self, a: usize) {
        self.a = a
        self.b = a
    }

    @move pub fn Slow(self, other: Self) {
        self.a = other.a
        self.b = other.b
    }

    pub fn op finally(self) {}
}

@no_inline fn take_plain(h: Handle) -> usize { return h.a }
@no_inline fn make_plain(a: usize) -> Handle { return Handle(a) }
@no_inline fn take_generic(b: Box<i32>) -> usize { return b.n }
@no_inline fn make_generic(n: usize) -> Box<i32> { return Box<i32>(n) }
@no_inline fn take_nested(o: Outer) -> usize { return o.h.a }
@no_inline fn make_nested(a: usize) -> Outer { return Outer(a) }
@no_inline fn take_slow(s: Slow) -> usize { return s.a }
@no_inline fn make_slow(a: usize) -> Slow { return Slow(a) }

fn main() -> i32 {
    var got = take_plain(make_plain(7)) + take_generic(make_generic(5)) + take_nested(make_nested(3)) + take_slow(make_slow(1))
    if got != 16 || live != 0 {
        return 1
    }

    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d/run && %t.exe

// REQUIRES: sysroot-x86_64-linux-gnu
// RUN: %kairo %s --emit=llvm-ir -O0 --target=x86_64-linux-gnu --cache-dir %t.d/x86
// RUN: %FileCheck %s --check-prefix=X86 < %t.d/x86/abi_registers.ll
// X86-DAG: define {{.*}}i64 @{{[A-Za-z0-9_]*}}take_plain{{[A-Za-z0-9_]*}}(i64 %{{[^,]*}}, i64 %{{[^,)]*}})
// X86-DAG: define {{.*}}{ i64, i64 } @{{[A-Za-z0-9_]*}}make_plain{{[A-Za-z0-9_]*}}(i64 noundef %{{[^,)]*}})
// X86-DAG: define {{.*}}i64 @{{[A-Za-z0-9_]*}}take_generic{{[A-Za-z0-9_]*}}(ptr %{{[^,]*}}, i64 %{{[^,)]*}})
// X86-DAG: define {{.*}}{ ptr, i64 } @{{[A-Za-z0-9_]*}}make_generic{{[A-Za-z0-9_]*}}(i64 noundef %{{[^,)]*}})
// X86-DAG: define {{.*}}i64 @{{[A-Za-z0-9_]*}}take_nested{{[A-Za-z0-9_]*}}(i64 %{{[^,]*}}, i64 %{{[^,)]*}})
// X86-DAG: define {{.*}}{ i64, i64 } @{{[A-Za-z0-9_]*}}make_nested{{[A-Za-z0-9_]*}}(i64 noundef %{{[^,)]*}})
// X86-DAG: define {{.*}}i64 @{{[A-Za-z0-9_]*}}take_slow{{[A-Za-z0-9_]*}}(ptr {{[^,)]*}})
// X86-DAG: define {{.*}}void @{{[A-Za-z0-9_]*}}make_slow{{[A-Za-z0-9_]*}}(ptr {{.*}}sret({{.*}}Slow{{.*}}) {{.*}}, i64 noundef %{{[^,)]*}})

// REQUIRES: sysroot-aarch64-linux-gnu
// RUN: %kairo %s --emit=llvm-ir -O0 --target=aarch64-linux-gnu --cache-dir %t.d/a64
// RUN: %FileCheck %s --check-prefix=A64 < %t.d/a64/abi_registers.ll
// A64-DAG: define {{.*}}i64 @{{[A-Za-z0-9_]*}}take_plain{{[A-Za-z0-9_]*}}([2 x i64] %{{[^,)]*}})
// A64-DAG: define {{.*}}[2 x i64] @{{[A-Za-z0-9_]*}}make_plain{{[A-Za-z0-9_]*}}(i64 noundef %{{[^,)]*}})
// A64-DAG: define {{.*}}i64 @{{[A-Za-z0-9_]*}}take_generic{{[A-Za-z0-9_]*}}([2 x i64] %{{[^,)]*}})
// A64-DAG: define {{.*}}[2 x i64] @{{[A-Za-z0-9_]*}}make_generic{{[A-Za-z0-9_]*}}(i64 noundef %{{[^,)]*}})
// A64-DAG: define {{.*}}i64 @{{[A-Za-z0-9_]*}}take_nested{{[A-Za-z0-9_]*}}([2 x i64] %{{[^,)]*}})
// A64-DAG: define {{.*}}[2 x i64] @{{[A-Za-z0-9_]*}}make_nested{{[A-Za-z0-9_]*}}(i64 noundef %{{[^,)]*}})
// A64-DAG: define {{.*}}i64 @{{[A-Za-z0-9_]*}}take_slow{{[A-Za-z0-9_]*}}(ptr {{[^,)]*}})
// A64-DAG: define {{.*}}void @{{[A-Za-z0-9_]*}}make_slow{{[A-Za-z0-9_]*}}(ptr {{.*}}sret({{.*}}Slow{{.*}}) {{.*}}, i64 noundef %{{[^,)]*}})
