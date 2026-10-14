// ADTs under load: payloads that own heap memory, nested inside other ADTs,
// copied, moved, assigned over, assigned to themselves, held by a class and
// a struct, and left from inside match arms by labeled break and continue.
// Cp and Mv each own one malloc'd i32, and `live` counts the ones not yet
// destroyed: a payload destroyed twice, never destroyed, or read after it
// is gone shows as a wrong count, a wrong value or a fault, and a leak or a
// double free shows under valgrind or ASan. Each part returns its own bit,
// or 0 on the first check that fails.

ffi "c" import "stdlib.h"

var live: i32 = 0

class Cp {
    var p: unsafe *i32
    pub fn Cp(self, v: i32) {
        unsafe { self.p = malloc(4) as unsafe *i32 }
        (*self.p) = v
        live += 1
    }
    @copy
    fn Cp(self, const other: Self) {
        unsafe { self.p = malloc(4) as unsafe *i32 }
        (*self.p) = *other.p
        live += 1
    }
    fn op delete(self) {
        unsafe { free(self.p as unsafe *void) }
        live -= 1
    }
    pub fn get(const self) -> i32 { return *self.p }
}

class Mv {
    var p: unsafe *i32
    pub fn Mv(self, v: i32) {
        unsafe { self.p = malloc(4) as unsafe *i32 }
        (*self.p) = v
        live += 1
    }
    @move
    fn Mv(self, other: Self) {
        self.p = other.p
        unsafe { other.p = &null }
        live += 1
    }
    fn op delete(self) {
        if self.p != &null { unsafe { free(self.p as unsafe *void) } }
        live -= 1
    }
    pub fn get(const self) -> i32 { return *self.p }
}

enum <T> Slot { One { v: T }, Two { a: T, b: T }, Empty }

enum <T> Outer { Inner { s: Slot<T>, k: i32 }, Bare { v: T }, Nil }

enum Leaf { Num { n: i32 }, Own { c: Cp }, Zero }
enum Node { Hold { l: Leaf }, Pair { a: Leaf, b: Leaf }, End }

fn slot_sum(const s: Slot<Cp>) -> i32 {
    return match s {
        case .One(const v)          => v.get()
        case .Two(const a, const b) => a.get() + b.get()
        case .Empty                 => 0
    }
}

fn outer_sum(const o: Outer<Cp>) -> i32 {
    return match o {
        case .Inner(const s, const k) => slot_sum(s) * 10 + k
        case .Bare(const v)           => v.get()
        case .Nil                     => -1
    }
}

fn leaf_val(const l: Leaf) -> i32 {
    return match l {
        case .Num(const n) => n
        case .Own(const c) => c.get()
        case .Zero         => 0
    }
}

fn node_val(const n: Node) -> i32 {
    return match n {
        case .Hold(const l)         => leaf_val(l)
        case .Pair(const a, const b) => leaf_val(a) * 100 + leaf_val(b)
        case .End                   => -1
    }
}

// Nested generic payloads: copy, assign, self-assign, reassign to another variant.
fn nested_generic() -> i32 {
    {
        var o = Outer<Cp>::Inner { s: Slot<Cp>::Two { a: Cp(1), b: Cp(2) }, k: 7 }
        var p = o
        if outer_sum(p) != 37 { return 0 }
        p = Outer<Cp>::Bare { v: Cp(9) }
        if outer_sum(p) != 9 { return 0 }
        p = o
        p = p
        if outer_sum(p) != 37 { return 0 }
        o = Outer<Cp>::Nil
        if outer_sum(o) != -1 { return 0 }
        if live != 2 { return 0 }
    }
    if live != 0 { return 0 }
    return 1
}

// A non-generic ADT holding a non-generic ADT holding a class.
fn nested_plain() -> i32 {
    {
        var n = Node::Pair { a: Leaf::Own { c: Cp(4) }, b: Leaf::Num { n: 5 } }
        var m = n
        if node_val(m) != 405 { return 0 }
        m = Node::Hold { l: Leaf::Own { c: Cp(6) } }
        m = m
        if node_val(m) != 6 { return 0 }
        n = m
        if node_val(n) != 6 { return 0 }
        if live != 2 { return 0 }
    }
    if live != 0 { return 0 }
    return 2
}

fn relay(@move s: Slot<Mv>) -> Slot<Mv> { return s }

fn mv_sum(const s: Slot<Mv>) -> i32 {
    return match s {
        case .One(const v)          => v.get()
        case .Two(const a, const b) => a.get() + b.get()
        case .Empty                 => 0
    }
}

// A generic ADT over a move-only class: moves through a parameter and a
// return, move-assignment from temporaries, nested.
fn generic_move() -> i32 {
    {
        var s = relay(Slot<Mv>::Two { a: Mv(3), b: Mv(4) })
        if mv_sum(s) != 7 { return 0 }
        s = Slot<Mv>::One { v: Mv(8) }
        if mv_sum(s) != 8 { return 0 }
        s = relay(Slot<Mv>::Empty)
        if mv_sum(s) != 0 { return 0 }
        var o = Outer<Mv>::Inner { s: Slot<Mv>::One { v: Mv(5) }, k: 1 }
        o = Outer<Mv>::Bare { v: Mv(2) }
        if live != 1 { return 0 }
    }
    if live != 0 { return 0 }
    return 4
}

fn make(i: i32) -> Slot<Cp> {
    if i % 3 == 0 { return Slot<Cp>::One { v: Cp(i) } }
    if i % 3 == 1 { return Slot<Cp>::Two { a: Cp(i), b: Cp(1) } }
    return Slot<Cp>::Empty
}

// break / continue to a label from inside match arms, with by-value
// bindings live at the jump.
fn labeled() -> i32 {
    var n = 0
    outer: for i in 0..20 {
        var s = make(i)
        for j in 0..3 {
            match s {
                case .One(var v) {
                    if v.get() == 9 { break outer }
                    if j == 1 { continue outer }
                    n += v.get()
                }
                case .Two(var a, var b) {
                    if j == 2 { continue outer }
                    n += a.get() + b.get()
                }
                case .Empty {
                    break
                }
            }
        }
        n += 1000
    }
    // i = 0: One(0), j0 adds 0, j1 continue          -> 0
    // i = 1: Two(1,1), j0 2, j1 2, j2 continue        -> 4
    // i = 2: Empty breaks the inner loop, then 1000  -> 1000
    // i = 3: One(3): 3, continue                     -> 3
    // i = 4: Two(4,1): 5 + 5                         -> 10
    // i = 5: Empty                                   -> 1000
    // i = 6: One(6): 6                               -> 6
    // i = 7: Two(7,1): 16                            -> 16
    // i = 8: Empty                                   -> 1000
    // i = 9: One(9): break outer
    if n != 3039 { return 0 }
    if live != 0 { return 0 }
    return 8
}

class Holder {
    pub var s: Slot<Cp>
    pub var tag: i32
}

struct Pair {
    var a: Outer<Cp>
    var b: Slot<Cp>
}

// A class and a struct holding ADTs: the derived `op =` assigns each member,
// and the ADT's own `op =` destroys the old payload and copies the new one.
fn holder_assign() -> i32 {
    {
        var h = Holder { s: Slot<Cp>::Two { a: Cp(2), b: Cp(3) }, tag: 1 }
        var g = Holder { s: Slot<Cp>::Empty, tag: 0 }
        g = h
        if (slot_sum(g.s) != 5) || (g.tag != 1) { return 0 }
        g = g
        if slot_sum(g.s) != 5 { return 0 }
        h.s = Slot<Cp>::One { v: Cp(7) }
        g = h
        if slot_sum(g.s) != 7 { return 0 }
        var p = Pair { a: Outer<Cp>::Bare { v: Cp(1) }, b: Slot<Cp>::One { v: Cp(2) } }
        var q = Pair { a: Outer<Cp>::Nil, b: Slot<Cp>::Empty }
        q = p
        q = q
        q.b = q.b
        if (outer_sum(q.a) != 1) || (slot_sum(q.b) != 2) { return 0 }
        if live != 6 { return 0 }
    }
    if live != 0 { return 0 }
    return 16
}

fn main() -> i32 {
    return nested_generic() + nested_plain() + generic_move() + labeled() + holder_assign()
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s -c --cache-dir %t.d/k
// RUN: %clangxx %t.d/k/*.o %t.d/k/builtin/*.o %t.d/k/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 31
// RUN: %kairo %s -c -O2 --cache-dir %t.d/o2
// RUN: %clangxx %t.d/o2/*.o %t.d/o2/builtin/*.o %t.d/o2/kairo/*.o -o %t.o2.exe
// RUN: %t.o2.exe; test $? -eq 31
