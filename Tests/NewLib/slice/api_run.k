// Every Slice member that does not need an element bound, on an empty, a
// one-element and a many-element slice: size and emptiness, get / at /
// first / last (null on a miss), begin / end, every range form at both
// ends, split_at at 0 and at the length, iter and iter_mut, windows and
// chunks with n below, equal to and above the length, the searches,
// equality, starts_with / ends_with, is_sorted, and the mutators.

import std::io

fn by_desc(a: *const i32, b: *const i32) -> Ordering {
    return *b <=> *a
}

fn key_mod(a: *const i32) -> i32 {
    return *a % 10
}

fn show(const tag: string, const s: [i32;]) {
    var t = f"{tag}:"
    for x in s {
        t += f" {x}"
    }

    io::println(t)
}

// COMPILER-WORKAROUND(const-element-extension): a member of `extend <T>
// Slice<T>` is not yet callable on the `[const T;]` that a `[T;]`'s range
// operator returns (sub_range_read_run.k); its length is counted.
fn len_of(const s: [const i32;]) -> usize {
    var n: usize = 0
    for x in s {
        n += 1
    }

    return n
}

fn reads(const tag: string, s: [i32;]) {
    var *f? = s.first()
    var *l? = s.last()
    var *g? = s.get(1)
    var *a? = s.at(-1)
    var *z? = s.at(0 - (s.size() as isize) - 1)
    var fs  = (if f? => f"{*f}" else => "null")
    var ls  = (if l? => f"{*l}" else => "null")
    var gs  = (if g? => f"{*g}" else => "null")
    var as_ = (if a? => f"{*a}" else => "null")
    io::println(f"{tag}: size {s.size()} empty {s.is_empty()} first {fs} last {ls} get1 {gs} at-1 {as_} at-big {!z?}")

    var *b? = s.begin()
    var *e? = s.end()
    if s.size() > 0 && b? && e? {
        unsafe {
            var span = (e as unsafe *const i32 as usize - b as unsafe *const i32 as usize) / 4
            io::println(f"{tag}: end - begin {span}")
        }
    }

    var n = s.size()
    io::println(f"{tag}: [0..n] {len_of(s[0..n])} [n..] {len_of(s[n..])} [..n] {len_of(s[..n])} [..=0] {(if n > 0 => len_of(s[..=0]) else => 0)} [0..0] {len_of(s[0..0])} [n..n] {len_of(s[n..n])}")
    var (l0, r0) = s.split_at(0)
    var (ln, rn) = s.split_at(n)
    io::println(f"{tag}: split 0 {len_of(l0)}/{len_of(r0)} split n {len_of(ln)}/{len_of(rn)}")

    var it = 0
    for p in s.iter() {
        it += *p
    }

    var w1 = 0
    var wn = 0
    var wb = 0
    for w in s.windows(1) {
        w1 += 1
    }

    if n > 0 {
        for w in s.windows(n) {
            wn += len_of(w) as i32
        }
    }

    for w in s.windows(n + 1) {
        wb += 1
    }

    var c2 = ""
    for c in s.chunks(2) {
        c2 += f"{len_of(c)}"
    }

    var cb = 0
    for c in s.chunks(n + 1) {
        cb += len_of(c) as i32
    }

    io::println(f"{tag}: iter {it} windows1 {w1} windowsN {wn} windowsBig {wb} chunks2 '{c2}' chunksBig {cb}")
    var i3? = s.index_of(3)
    var l3? = s.last_index_of(3)
    io::println(f"{tag}: contains3 {s.contains(3)} in {3 in s} index3 {i3 ?? 99} last3 {l3 ?? 99} sorted {s.is_sorted()}")
}

fn main() -> i32 {
    var none: [i32]
    var one: [i32]  = [3]
    var many: [i32] = [5, 3, 9, 1, 3, 7, 2]
    var e: [i32;] = none
    var s: [i32;] = many
    var o: [i32;] = one
    reads("empty", e)
    reads("one", o)
    reads("many", s)

    e.reverse()
    e.rotate(5)
    e.sort_by(by_desc)
    show("empty mutated", e)

    o.reverse()
    o.rotate(-7)
    o.sort_by(by_desc)
    show("one mutated", o)

    s.reverse()
    show("reverse", s)
    s.rotate(2)
    show("rotate 2", s)
    s.rotate(-2)
    show("rotate -2", s)
    s.swap(0, 6)
    s.swap(3, 3)
    show("swap", s)
    s.sort_by(by_desc)
    show("sort_by desc", s)
    s.sort_by_key(key_mod)
    show("sort_by_key", s)
    for p in s.iter_mut() {
        *p *= 2
    }

    show("iter_mut", s)
    s[1..3].reverse()
    show("range write", s)
    var *g? = s.get_mut(0)
    if g? {
        *g = 100
    }

    var *m? = s.get_mut(7)
    io::println(f"get_mut 7 null {!m?}")
    var (a, b) = s.split_at_mut(3)
    a.swap(0, 2)
    b[0] = -1
    show("split_at_mut", s)

    var w: [i32]   = [1, 2, 3, 4]
    var x: [i32]   = [1, 2, 3, 4]
    var y: [i32]   = [1, 2, 3]
    var ws: [i32;] = w
    io::println(f"eq {ws == x} ne-len {ws == y} prefix {ws.starts_with(y)} suffix {ws.ends_with(ws[2..])} not-suffix {ws.ends_with(y)}")
    return 0
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// RUN: %kairo_new %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe | %FileCheck %s --match-full-lines
// CHECK:      empty: size 0 empty true first null last null get1 null at-1 null at-big true
// CHECK-NEXT: empty: [0..n] 0 [n..] 0 [..n] 0 [..=0] 0 [0..0] 0 [n..n] 0
// CHECK-NEXT: empty: split 0 0/0 split n 0/0
// CHECK-NEXT: empty: iter 0 windows1 0 windowsN 0 windowsBig 0 chunks2 '' chunksBig 0
// CHECK-NEXT: empty: contains3 false in false index3 99 last3 99 sorted true
// CHECK-NEXT: one: size 1 empty false first 3 last 3 get1 null at-1 3 at-big true
// CHECK-NEXT: one: end - begin 1
// CHECK-NEXT: one: [0..n] 1 [n..] 0 [..n] 1 [..=0] 1 [0..0] 0 [n..n] 0
// CHECK-NEXT: one: split 0 0/1 split n 1/0
// CHECK-NEXT: one: iter 3 windows1 1 windowsN 1 windowsBig 0 chunks2 '1' chunksBig 1
// CHECK-NEXT: one: contains3 true in true index3 0 last3 0 sorted true
// CHECK-NEXT: many: size 7 empty false first 5 last 2 get1 3 at-1 2 at-big true
// CHECK-NEXT: many: end - begin 7
// CHECK-NEXT: many: [0..n] 7 [n..] 0 [..n] 7 [..=0] 1 [0..0] 0 [n..n] 0
// CHECK-NEXT: many: split 0 0/7 split n 7/0
// CHECK-NEXT: many: iter 30 windows1 7 windowsN 7 windowsBig 0 chunks2 '2221' chunksBig 7
// CHECK-NEXT: many: contains3 true in true index3 1 last3 4 sorted false
// CHECK-NEXT: empty mutated:
// CHECK-NEXT: one mutated: 3
// CHECK-NEXT: reverse: 2 7 3 1 9 3 5
// CHECK-NEXT: rotate 2: 3 1 9 3 5 2 7
// CHECK-NEXT: rotate -2: 2 7 3 1 9 3 5
// CHECK-NEXT: swap: 5 7 3 1 9 3 2
// CHECK-NEXT: sort_by desc: 9 7 5 3 3 2 1
// CHECK-NEXT: sort_by_key: 1 2 3 3 5 7 9
// CHECK-NEXT: iter_mut: 2 4 6 6 10 14 18
// CHECK-NEXT: range write: 2 6 4 6 10 14 18
// CHECK-NEXT: get_mut 7 null true
// CHECK-NEXT: split_at_mut: 4 6 100 -1 10 14 18
// CHECK-NEXT: eq true ne-len false prefix true suffix true not-suffix false
