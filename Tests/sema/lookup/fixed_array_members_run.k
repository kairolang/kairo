// A fixed array `[T; N]` has the members of its slice view: `a.m(args)`
// means `a[0..].m(args)`, a view over the array's own storage, so a
// mutating member changes the array. A const array, and one reached
// through a const path, is viewed as `[const T;]` and keeps every member
// that only reads. Covered: the queries, the searches and `in`, equality,
// the mutators, the views (split_at, windows, chunks, iter), to_owned and
// the pointer accessor, on a local, a const local, a `const` and an
// `@inout` parameter, a field through `self` and through `const self`, a
// nested array, a pointer to an array, and an array of a move-only class.

import std::io

fn by_desc(a: *const i32, b: *const i32) -> Ordering {
    return *b <=> *a
}

fn key_mod(a: *const i32) -> i32 {
    return *a % 10
}

fn show(const tag: string, const s: [const i32;]) {
    var t = f"{tag}:"
    for x in s {
        t += f" {x}"
    }

    io::println(t)
}

fn reads(const tag: string, const a: [i32; 5]) {
    var *f? = a.first()
    var *l? = a.last()
    var *g? = a.get(1)
    var *m? = a.get(5)
    var *t? = a.at(-1)
    var fs = (if f? => f"{*f}" else => "null")
    var ls = (if l? => f"{*l}" else => "null")
    var gs = (if g? => f"{*g}" else => "null")
    var ts = (if t? => f"{*t}" else => "null")
    io::println(f"{tag}: size {a.size()} empty {a.is_empty()} first {fs} last {ls} get1 {gs} get5 {!m?} at-1 {ts}")
    var i3? = a.index_of(3)
    var l3? = a.last_index_of(3)
    io::println(f"{tag}: contains3 {a.contains(3)} in3 {3 in a} in8 {8 in a} index3 {i3 ?? 99} last3 {l3 ?? 99} sorted {a.is_sorted()}")
}

fn bump(@inout a: [i32; 5]) {
    a.reverse()
    a.swap(0, 4)
}

class Ring {
    pub var buf: [i32; 4] = [4, 3, 2, 1]

    pub fn Ring(self) { }

    pub fn total(const self) -> usize {
        var n: usize = 0
        for x in self.buf.iter() {
            n += (*x) as usize
        }

        return n + self.buf.size()
    }

    pub fn order(self) {
        self.buf.sort()
    }
}

class Tok {
    pub var n: i32 = 0

    pub fn Tok(self, n: i32) {
        self.n = n
    }

    @move pub fn Tok(self, other: Self) {
        self.n = other.n
        other.n = 0
    }
}

fn main() -> i32 {
    var a: [i32; 5] = [5, 3, 9, 1, 3]
    reads("var", a)
    const c: [i32; 5] = [1, 3, 3, 7, 9]
    reads("const", c)
    io::println(f"const: size {c.size()} sorted {c.is_sorted()} search7 {c.binary_search(7).1}")

    // The read members on a mutable array, not through a const parameter.
    var *ml? = a.last()
    var *mg? = a.get(2)
    var *mt? = a.at(-2)
    var mi? = a.index_of(9)
    var mj? = a.last_index_of(5)
    var mls = (if ml? => f"{*ml}" else => "null")
    var mgs = (if mg? => f"{*mg}" else => "null")
    var mts = (if mt? => f"{*mt}" else => "null")
    io::println(f"mutable: empty {a.is_empty()} last {mls} get2 {mgs} at-2 {mts} contains9 {a.contains(9)} in9 {9 in a} index9 {mi ?? 99} last5 {mj ?? 99} sorted {a.is_sorted()}")

    // The view members on a const array.
    const d: [i32; 4] = [2, 4, 6, 8]
    const d2: [i32; 4] = [2, 4, 6, 8]
    var (dl, dr) = d.split_at(1)
    var dw = 0
    for x in d.windows(2) {
        dw += 1
    }

    var dk = ""
    for x in d.chunks(3) {
        dk += f"{x.size()}"
    }

    var dv = d.to_owned()
    var *dp? = d.data()
    var dps = (if dp? => f"{*dp}" else => "null")
    io::println(f"const views: split {dl.size()}/{dr.size()} windows {dw} chunks '{dk}' owned {dv.size()} eq {d == d2} prefix {d.starts_with(dl)} suffix {d.ends_with(dr)} data {dps}")

    // Mutators write through the view into the array.
    a.sort()
    show("sort", a)
    a.reverse()
    show("reverse", a)
    a.rotate(2)
    show("rotate 2", a)
    a.swap(0, 4)
    show("swap", a)
    a.sort_by(by_desc)
    show("sort_by desc", a)
    a.sort_by_key(key_mod)
    show("sort_by_key", a)
    a.sort_unstable()
    show("sort_unstable", a)
    bump(&a)
    show("inout", a)
    var *g? = a.get_mut(1)
    if g? {
        *g = 42
    }

    show("get_mut", a)
    var *dm? = a.data_mut()
    if dm? {
        *dm = 11
    }

    show("data_mut", a)
    a.fill(7)
    show("fill", a)
    var z: [i32; 3]
    z.fill(2)
    show("fill uninitialised", z)

    // Views and copies of the elements.
    var b: [i32; 6] = [1, 2, 3, 4, 5, 6]
    var (l, r) = b.split_at(2)
    var w = 0
    for x in b.windows(3) {
        w += 1
    }

    var k = ""
    for x in b.chunks(4) {
        k += f"{x.size()}"
    }

    var v = b.to_owned()
    v.push(7)
    var e: [i32; 6] = [1, 2, 3, 4, 5, 6]
    var *p? = b.data()
    var ps = (if p? => f"{*p}" else => "null")
    io::println(f"views: split {l.size()}/{r.size()} windows {w} chunks '{k}' owned {v.size()} eq {b == e} ne {b != a} prefix {b.starts_with(l)} suffix {b.ends_with(r)} data {ps}")

    // A nested array: the outer extent, then the row's.
    var grid: [[i32; 3]; 2] = [[3, 2, 1], [6, 5, 4]]
    grid[1].sort()
    io::println(f"grid: rows {grid.size()} cols {grid[0].size()} row1 {grid[1][0]} {grid[1][2]}")

    // A field, through `self` and `const self`.
    var ring = Ring()
    ring.order()
    io::println(f"ring: first {ring.buf[0]} total {ring.total()} size {ring.buf.size()}")

    // Through a pointer to the array.
    var pa: *[i32; 5] = &a
    pa->fill(1)
    io::println(f"pointer: size {pa->size()} sum {a[0] + a[4]}")

    // Move-only elements: the view moves nothing.
    var toks: [Tok; 3] = [Tok(1), Tok(2), Tok(3)]
    toks.swap(0, 2)
    toks.reverse()
    var *t0? = toks.first()
    io::println(f"move-only: size {toks.size()} first {(if t0? => t0->n else => -1)} last {toks[2].n}")
    return 0
}

// --- lit wiring ---
// RUN: rm -f %t.exe
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe | %FileCheck %s --match-full-lines
// RUN: rm -f %t.o2.exe
// RUN: %kairo %s -O2 -o %t.o2.exe
// RUN: %t.o2.exe | %FileCheck %s --match-full-lines
// CHECK:      var: size 5 empty false first 5 last 3 get1 3 get5 true at-1 3
// CHECK-NEXT: var: contains3 true in3 true in8 false index3 1 last3 4 sorted false
// CHECK-NEXT: const: size 5 empty false first 1 last 9 get1 3 get5 true at-1 9
// CHECK-NEXT: const: contains3 true in3 true in8 false index3 1 last3 2 sorted true
// CHECK-NEXT: const: size 5 sorted true search7 3
// CHECK-NEXT: mutable: empty false last 3 get2 9 at-2 1 contains9 true in9 true index9 2 last5 0 sorted false
// CHECK-NEXT: const views: split 1/3 windows 3 chunks '31' owned 4 eq true prefix true suffix true data 2
// CHECK-NEXT: sort: 1 3 3 5 9
// CHECK-NEXT: reverse: 9 5 3 3 1
// CHECK-NEXT: rotate 2: 3 3 1 9 5
// CHECK-NEXT: swap: 5 3 1 9 3
// CHECK-NEXT: sort_by desc: 9 5 3 3 1
// CHECK-NEXT: sort_by_key: 1 3 3 5 9
// CHECK-NEXT: sort_unstable: 1 3 3 5 9
// CHECK-NEXT: inout: 1 5 3 3 9
// CHECK-NEXT: get_mut: 1 42 3 3 9
// CHECK-NEXT: data_mut: 11 42 3 3 9
// CHECK-NEXT: fill: 7 7 7 7 7
// CHECK-NEXT: fill uninitialised: 2 2 2
// CHECK-NEXT: views: split 2/4 windows 4 chunks '42' owned 7 eq true ne true prefix true suffix true data 1
// CHECK-NEXT: grid: rows 2 cols 3 row1 4 6
// CHECK-NEXT: ring: first 1 total 14 size 4
// CHECK-NEXT: pointer: size 5 sum 2
// CHECK-NEXT: move-only: size 3 first 1 last 3
