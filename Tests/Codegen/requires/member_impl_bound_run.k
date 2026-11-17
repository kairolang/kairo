// A member's `requires T impl I` (T a parameter of its record) gives the
// body I's members on T, as a bound in the parameter list does, and the
// emitted member runs: an insertion sort and a fill through the container's
// pointer, a conjunction, a generic interface whose argument is the
// member's own parameter or the record's, an extension member's clause, an
// extension header's clause, and a bounded member calling a bounded
// function. The same class instantiated for a type that meets none of the
// clauses compiles and runs as long as no bounded member is called.

import std::io::println

interface Less {
    fn op <(const self, const o: Self) -> bool
}

interface Zero {
    fn zero() -> Self
}

interface Same {
    fn same(const self, const o: Self) -> bool
}

interface <U> FromInt {
    fn from_int(const u: U) -> Self
}

class Num {
    pub var v: i32
    pub fn Num(self) { self.v = 0 }
    pub fn Num(self, v: i32) { self.v = v }
    pub fn op <(const self, const o: Num) -> bool { return self.v < o.v }
    pub static fn zero() -> Num { return Num(0) }
    pub fn same(const self, const o: Num) -> bool { return self.v == o.v }
    pub static fn from_int(const u: i32) -> Num { return Num(u * 10) }
}

// Has none of the interfaces.
class Opaque {
    pub var v: i32
    pub fn Opaque(self) { self.v = 0 }
    pub fn Opaque(self, v: i32) { self.v = v }
}

fn <U impl Same> same_twice(const a: U) -> bool { return a.same(a) }

class <T> Buf {
    pub var p: unsafe *T
    pub var n: usize

    pub fn Buf(self, p: unsafe *T, n: usize) {
        self.p = p
        self.n = n
    }

    pub fn len(const self) -> usize { return self.n }

    pub fn at(const self, i: usize) -> unsafe *T { return unsafe (self.p + i) }

    // Insertion sort through the pointer: the operands are `*T` reads.
    pub fn sort(self) requires T impl Less {
        for var i: usize = 1; i < self.n; ++i {
            var j = i
            while j > 0 && unsafe (*self.at(j)) < unsafe (*self.at(j - 1)) {
                var t = unsafe (*self.at(j))
                unsafe { *self.at(j) = *self.at(j - 1) }
                unsafe { *self.at(j - 1) = t }
                j -= 1
            }
        }
    }

    pub fn fill(self) requires T impl Zero {
        for var i: usize = 0; i < self.n; ++i {
            unsafe { *self.at(i) = T::zero() }
        }
    }

    pub fn count(const self, const v: T) -> i32 requires T impl Same && T impl Less {
        var k = 0
        for var i: usize = 0; i < self.n; ++i {
            var w = unsafe (*self.at(i))
            if w.same(v) || !(w < v || v < w) {
                k += 1
            }
        }

        return k
    }

    // Calls a bounded function: an instance this member is dropped from
    // reaches no instance of it.
    pub fn twice(const self, const v: T) -> bool requires T impl Same { return same_twice(v) }

    // The interface's argument is the record's parameter.
    pub fn <C> convert(const self, i: usize) -> C requires C impl FromInt<T> {
        return C::from_int(unsafe (*self.at(i)))
    }

    pub fn <U> set_from(self, i: usize, const u: U) requires T impl FromInt<U> {
        unsafe { *self.at(i) = T::from_int(u) }
    }
}

extend <T> Buf<T> {
    pub fn smallest(const self) -> T requires T impl Less {
        var m = unsafe (*self.at(0))
        for var i: usize = 1; i < self.n; ++i {
            if unsafe (*self.at(i)) < m {
                m = unsafe (*self.at(i))
            }
        }

        return m
    }
}

extend <T> Buf<T> requires T impl Same {
    pub fn has(const self, const v: T) -> bool {
        for var i: usize = 0; i < self.n; ++i {
            if unsafe (*self.at(i)).same(v) {
                return true
            }
        }

        return false
    }
}

fn main() -> i32 {
    var xs: [Num; 4] = [Num(3), Num(1), Num(4), Num(1)]
    var b = Buf<Num>(unsafe &xs[0], 4)
    b.sort()
    println(f"{xs[0].v} {xs[1].v} {xs[2].v} {xs[3].v}")
    println(f"{b.count(Num(1))} {b.smallest().v} {b.has(Num(4))} {b.has(Num(9))}")
    b.set_from(0, 7)
    println(f"{xs[0].v}")
    b.fill()
    println(f"{xs[0].v} {xs[3].v} {b.twice(Num(2))}")
    var ns: [i32; 2] = [4, 5]
    var nb = Buf<i32>(unsafe &ns[0], 2)
    println(f"{nb.convert<Num>(1).v}")

    // Never calls a bounded member: Buf<Opaque> compiles.
    var os: [Opaque; 2] = [Opaque(5), Opaque(6)]
    var ob = Buf<Opaque>(unsafe &os[0], 2)
    println(f"{ob.len()} {unsafe (*ob.at(1)).v}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// CHECK: 1 1 3 4
// CHECK-NEXT: 2 1 true false
// CHECK-NEXT: 70
// CHECK-NEXT: 0 0 true
// CHECK-NEXT: 50
// CHECK-NEXT: 2 6
