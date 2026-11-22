// A field moved out of a local (`var x = p.a`) leaves the rest of the local
// to be destroyed as usual, without that field (ownership.mdx, Moved-From
// State): its moved-from object is not destroyed. That is done when the
// same fields are moved out on every path to every exit and the local's
// class, and each class on the way to a nested field, has no destructor
// of its own and no base. C's move zeroes its source, so a destroyed
// moved-from object prints `~C 0`; every run ends `made == released`.
//  - one / two / nested / generic: one field, two fields, a field of a
//    field (the rest destroyed last field first, the outer class's own
//    fields before the inner one's), a field of a generic class instance.
// Unchanged, each with its `~C 0`: a field moved on one path only
// (one_path), a return before the move (early), a class with a
// destructor body (owned), a moved field assigned again (reassigned), and
// a class of another namespace whose fields this function is not
// befriended for (far).
import std::io::println

var made: i32 = 0
var released: i32 = 0

class C {
    var id: i32 = 0
    fn C(self, id: i32) {
        self.id = id
        made += 1
    }
    @move fn C(self, other: Self) {
        self.id  = other.id
        other.id = 0
    }
    fn op finally(self) {
        if self.id != 0 {
            released += 1
        }
        println(f"~C {self.id}")
    }
}

class Pair {
    var a: C
    var b: C
    fn Pair(self, x: i32, y: i32) {
        self.a = C(x)
        self.b = C(y)
    }
}

class Three {
    var a: C
    var b: C
    var c: C
    fn Three(self, x: i32) {
        self.a = C(x)
        self.b = C(x + 1)
        self.c = C(x + 2)
    }
}

class Outer {
    var p: Pair
    var z: C
    var n: i32 = 0
    fn Outer(self, k: i32) {
        self.p = Pair(k, k + 1)
        self.z = C(k + 2)
    }
}

class Owned {
    var a: C
    var b: C
    fn Owned(self, x: i32, y: i32) {
        self.a = C(x)
        self.b = C(y)
    }
    fn op finally(self) { println("~Owned") }
}

class <T> Box {
    var v: T
    var w: C
    fn Box(self, v: T, k: i32) {
        self.v = v
        self.w = C(k)
    }
}

module inner {
    pub class Far {
        pub var a: C
        var b: C
        pub fn Far(self, x: i32, y: i32) {
            self.a = C(x)
            self.b = C(y)
        }
    }
}

fn one() {
    var p = Pair(1, 2)
    var x = p.a
    println("one end")
}

fn two() {
    var p = Three(3)
    var x = p.a
    var y = p.c
    println("two end")
}

fn nested() {
    var o = Outer(6)
    var x = o.p.a
    println("nested end")
}

fn generic() {
    var b = Box<C>(C(9), 10)
    var x = b.v
    println("generic end")
}

fn one_path(c: bool) {
    var p = Pair(11, 12)
    if c {
        var x = p.a
    }
    println("one_path end")
}

fn early(c: bool) {
    var p = Pair(13, 14)
    if c {
        println("early return")
        return
    }
    var x = p.a
    println("early end")
}

fn owned() {
    var p = Owned(15, 16)
    var x = p.a
    println("owned end")
}

fn reassigned() {
    var p = Pair(17, 18)
    var x = p.a
    p.a = C(19)
    println("reassigned end")
}

fn far() {
    var f = inner::Far(20, 21)
    var x = f.a
    println("far end")
}

fn main() -> i32 {
    one()
    two()
    nested()
    generic()
    one_path(true)
    one_path(false)
    early(true)
    early(false)
    owned()
    reassigned()
    far()
    println(f"made {made} released {released}")
    return if (made == released) => (0) else => 1
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// The hook destroys what is left, last field first.
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: void one() noexcept {
// CXX: ::__kairo_ul< ::{{.*}}::Pair> __k_s_p {
// CXX: +[](void * q) noexcept {
// CXX-NEXT: auto & v = static_cast< ::__kairo_ul< ::{{.*}}::Pair> *>(q)->v;
// CXX-NEXT: ::__kairo_ul_kill(v.b);
// CXX-NEXT: }
// CXX-LABEL: void nested() noexcept {
// CXX: auto & v = static_cast< ::__kairo_ul< ::{{.*}}::Outer> *>(q)->v;
// CXX-NEXT: ::__kairo_ul_kill(v.n);
// CXX-NEXT: ::__kairo_ul_kill(v.z);
// CXX-NEXT: ::__kairo_ul_kill(v.p.b);
// CXX-NEXT: }
// CXX-LABEL: void one_path(bool c) noexcept {
// CXX-NOT: __kairo_ul
// CXX: void early(bool c) noexcept {

// REQUIRES: clang
// RUN: rm -rf %t.d %t.o2.d %t.off.d
// RUN: rm -f %t.exe %t.o2.exe %t.off.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT --match-full-lines
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.o2.d
// RUN: %t.o2.exe | %FileCheck %s --check-prefix=OUT --match-full-lines
// RUN: %kairo %s -fno-destructive-moves -o %t.off.exe --cache-dir %t.off.d
// RUN: %t.off.exe
// OUT:      one end
// OUT-NEXT: ~C 1
// OUT-NEXT: ~C 2
// OUT-NEXT: two end
// OUT-NEXT: ~C 5
// OUT-NEXT: ~C 3
// OUT-NEXT: ~C 4
// OUT-NEXT: nested end
// OUT-NEXT: ~C 6
// OUT-NEXT: ~C 8
// OUT-NEXT: ~C 7
// OUT-NEXT: ~C 0
// OUT-NEXT: generic end
// OUT-NEXT: ~C 9
// OUT-NEXT: ~C 10
// OUT-NEXT: ~C 11
// OUT-NEXT: one_path end
// OUT-NEXT: ~C 12
// OUT-NEXT: ~C 0
// OUT-NEXT: one_path end
// OUT-NEXT: ~C 12
// OUT-NEXT: ~C 11
// OUT-NEXT: early return
// OUT-NEXT: ~C 14
// OUT-NEXT: ~C 13
// OUT-NEXT: early end
// OUT-NEXT: ~C 13
// OUT-NEXT: ~C 14
// OUT-NEXT: ~C 0
// OUT-NEXT: owned end
// OUT-NEXT: ~C 15
// OUT-NEXT: ~Owned
// OUT-NEXT: ~C 16
// OUT-NEXT: ~C 0
// OUT-NEXT: ~C 0
// OUT-NEXT: ~C 0
// OUT-NEXT: reassigned end
// OUT-NEXT: ~C 17
// OUT-NEXT: ~C 18
// OUT-NEXT: ~C 19
// OUT-NEXT: far end
// OUT-NEXT: ~C 20
// OUT-NEXT: ~C 21
// OUT-NEXT: ~C 0
// OUT-NEXT: made 25 released 25
// OUT-EMPTY:
