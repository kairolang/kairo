// SC224W over loops: a by-value parameter of a non-trivially-copyable type
// that the body only iterates is never mutated, since a loop without a
// mutable pointer binder reads through `op in (const self)`. The fix-it
// writes `const`, and the fixed file compiles. Every parameter below
// `reads` is mutated, moved, written through, or not a candidate, and is
// not warned.

struct Pt {
    var x: i32
    var y: i32
}

class Owned {
    var n: i32 = 0
    fn Owned(self) { }
    @move fn Owned(self, other: Self) { self.n = other.n }
}

fn take(@move o: Owned) -> i32 {
    return o.n
}

fn grow(@inout v: Bag) {
    v.push(1)
}

fn reads(v: Bag, s: Bag) -> i32 {
    var n = 0
    for x in v {
        n += x
    }

    for const x in s {
        n += x
    }

    return n
}

fn writes_through(v: Bag) -> i32 {
    var n = 0
    for *x in v {
        *x += 1
        n += *x
    }

    return n
}

fn mutated(v: Bag) -> i32 {
    v.push(4)
    var n = 0
    for x in v {
        n += x
    }

    return n
}

fn passed_inout(v: Bag) -> i32 {
    grow(&v)
    var n = 0
    for x in v {
        n += x
    }

    return n
}

fn address_taken(v: Bag) -> i32 {
    var *p = &v
    var n = 0
    for x in v {
        n += x
    }

    return n + p->size() as i32
}

fn moved(o: Owned) -> i32 {
    return take(o)
}

fn trivial(p: Pt) -> i32 {
    return p.x + p.y
}

fn already(const v: Bag) -> i32 {
    var n = 0
    for x in v {
        n += x
    }

    return n
}

fn main() -> i32 {
    var v = Bag(1)
    v.push(2)
    var s = Bag(3)
    var r = reads(v, s) + writes_through(v) + mutated(v) + passed_inout(v)
    r += address_taken(v) + moved(Owned()) + trivial(Pt { x: 1, y: 1 }) + already(v)
    // 6 + 5 + 7 + 4 + 5 + 0 + 2 + 3
    return r - 32
}

class Bag {
    var xs: [i32]
    fn Bag(self) { self.xs = [] }
    fn Bag(self, x: i32) { self.xs = []; self.xs.push(x) }
    @copy fn Bag(self, const o: Self) { self.xs = o.xs.copy() }
    fn push(self, x: i32) { self.xs.push(x) }
    fn size(const self) -> usize { return self.xs.size() }
    fn op in (self) -> yield *i32 { for *x in self.xs { yield x } }
    fn op in (const self) -> yield *const i32 { for const *x in self.xs { yield x } }
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="warning [SC224W]" --implicit-check-not="error ["
// RUN: rm -rf %t && mkdir -p %t && cp %s %t/pm.k
// RUN: { %kairo %t/pm.k --type-check-only 2>&1 || true; } > %t/diag.txt
// RUN: python3 %S/../../../Scripts/apply_fixits.py --code SC224W --from %t/diag.txt 2>&1 | %FileCheck %s --check-prefix=APPLIED
// RUN: { %kairo %t/pm.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=AFTER --allow-empty --implicit-check-not="warning [SC224W]"
// RUN: %kairo %t/pm.k -w -o %t/pm.exe --cache-dir %t/c
// RUN: %t/pm.exe
//
// CHECK: param_never_mutated_loop.k:27:10: warning [SC224W]: parameter 'v' is never mutated; declare it 'const'
// CHECK-NEXT: fix-it:"{{.*}}param_never_mutated_loop.k":{27:10-27:10}:"const "
// CHECK: param_never_mutated_loop.k:27:18: warning [SC224W]: parameter 's' is never mutated; declare it 'const'
// CHECK-NEXT: fix-it:"{{.*}}param_never_mutated_loop.k":{27:18-27:18}:"const "
//
// APPLIED: changed 1 file(s)
// AFTER-NOT: SC224W
