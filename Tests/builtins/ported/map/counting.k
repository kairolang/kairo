// Ownership of entries in HashMap<K, V>, counted: a class that records its
// constructions, moves, copies and destructions separately and checks each
// object is moved from only while live and destroyed once. Covers insert
// (moves in, destroys what it replaces only when the caller drops the
// returned value), remove, clear, retain, merge, copy (one copy per value),
// growth, and the drop of the map itself, for a value, a key and a pair of
// counted classes.
//
// Cases from libc++ test/std/containers/unord/unord.map/ (insert, erase, clear, copy, move, swap_non_member)
// Cases from Rust library/std/src/collections/hash/map/tests.rs (test_drops, clone, drop_panic_leak without the panic)
// Cases from hashbrown src/map.rs tests (drops, clone, clone_from, clone double drop)

import std::io

var checks: u64 = 0
var failures: u64 = 0
var made: i64 = 0
var moved: i64 = 0
var copied: i64 = 0
var gone: i64 = 0
var errors: u64 = 0

fn ck(cond: bool, const what: string) {
    checks += 1
    if !cond {
        failures += 1
        io::println(f"FAIL {what}")
    }
}

fn reset() {
    made = 0
    moved = 0
    copied = 0
    gone = 0
}

fn live() -> i64 { return made + moved + copied - gone }

class Cnt {
    pub var v: u64
    var state: u64

    pub fn Cnt(self, v: u64) {
        self.v = v
        self.state = 1
        made += 1
    }

    @move pub fn Cnt(self, other: Self) {
        if other.state != 1 { errors += 1 }
        self.v = other.v
        self.state = 1
        other.state = 2
        moved += 1
    }

    pub fn op finally(self) {
        if self.state == 0 { errors += 1 }
        self.state = 0
        gone += 1
    }
}

extend Cnt impl Copyable {
    fn copy(const self) -> Cnt {
        if self.state != 1 { errors += 1 }
        copied += 1
        var c = Cnt(self.v)
        made -= 1
        return c
    }
}

extend Cnt impl Hash {
    fn hash(const self, @inout h: Hasher) { h.write_u64(self.v) }
    fn op == (const self, const o: Cnt) -> bool { return self.v == o.v }
}

fn drop_odd(k: *const u64, v: *Cnt) -> bool { return v->v % 2 == 0 }

fn pick_new(a: Cnt, b: Cnt) -> Cnt { return Cnt(a.v * 1000 + b.v) }

fn test_drop_of_map() {
    reset()
    {
        var m: {u64: Cnt}
        for var i: u64 = 0; i < 100; i += 1 { m.insert(i, Cnt(i)) }
        ck(live() == 100, "drop: one live object per entry")
        ck(copied == 0, "insert copies nothing")
    }
    ck(live() == 0 && errors == 0, "drop of a map destroys every value once")
    reset()
    {
        var m: {u64: Cnt}
        for var i: u64 = 0; i < 3; i += 1 { m.insert(i, Cnt(i)) }
    }
    ck(live() == 0, "drop of a map with three entries")
    reset()
    {
        var e: {u64: Cnt}
        var f = e
    }
    ck(live() == 0 && made == 0, "drop of an empty map creates and destroys nothing")
}

fn test_replace_and_remove() {
    reset()
    {
        var m: {u64: Cnt}
        for var i: u64 = 0; i < 50; i += 1 { m.insert(i, Cnt(i)) }
        var old? = m.insert(7, Cnt(700))
        ck(old? && old.v == 7 && live() == 51, "insert hands the replaced value to the caller")
        old = null
        ck(live() == 50, "the dropped return value is destroyed once")
        m.insert(8, Cnt(800))
        ck(live() == 50, "a discarded return value is destroyed by the statement")
        var r? = m.swap_remove(9)
        r = null
        var s? = m.shift_remove(10)
        s = null
        var p? = m.pop()
        p = null
        ck(m.size() == 47, "three entries removed")
        ck(live() == 47, "swap_remove, shift_remove and pop give their value out and it is destroyed once")
        var t? = m.try_insert(20, Cnt(2000))
        ck(t? && live() == 48, "try_insert on a present key returns the new object")
        t = null
        ck(live() == 47, "dropped")
    }
    ck(live() == 0 && errors == 0, "replace and remove: no leak, no double destroy")
}

fn test_setter() {
    reset()
    {
        var m: {u64: Cnt}
        m[1] = Cnt(10)
        m[2] = Cnt(20)
        ck(live() == 2 && m[1].v == 10, "setter inserts")
        m[1] = Cnt(11)
        ck(live() == 2 && m[1].v == 11, "setter destroys the value it replaces")
        ck(copied == 0, "setter copies no value")
    }
    ck(live() == 0 && errors == 0, "setter: no leak")
}

fn test_clear_and_retain() {
    reset()
    {
        var m: {u64: Cnt}
        for var i: u64 = 0; i < 200; i += 1 { m.insert(i, Cnt(i)) }
        m.retain(drop_odd)
        ck(m.size() == 100 && live() == 100, "retain destroys exactly the refused entries")
        var bad: u64 = 0
        for var i: u64 = 0; i < 200; i += 2 {
            if m[i].v != i { bad += 1 }
        }
        ck(bad == 0, "retain keeps the accepted values")
        m.clear()
        ck(m.size() == 0 && live() == 0, "clear destroys every value")
        m.clear()
        ck(live() == 0, "clear of an empty map")
        for var i: u64 = 0; i < 10; i += 1 { m.insert(i, Cnt(i)) }
        ck(live() == 10, "refill after clear")
    }
    ck(live() == 0 && errors == 0, "clear and retain: no leak, no double destroy")
}

fn test_copy() {
    reset()
    {
        var m: {u64: Cnt}
        for var i: u64 = 0; i < 40; i += 1 { m.insert(i, Cnt(i)) }
        var c = m.copy()
        ck(copied == 40 && live() == 80, "copy makes one copy per value (deep)")
        var bad: u64 = 0
        for var i: u64 = 0; i < 40; i += 1 {
            if c[i].v != i { bad += 1 }
        }
        ck(bad == 0, "copied values equal the originals")
        m.clear()
        ck(live() == 40 && c.size() == 40, "clearing the original leaves the copy")
        var d = c.copy()
        ck(live() == 80, "a copy of a copy")
    }
    ck(live() == 0 && errors == 0, "copy: no leak, no double destroy")
    reset()
    {
        var e: {u64: Cnt}
        var c = e.copy()
        ck(copied == 0 && made == 0, "copy of an empty map makes nothing")
    }
}

fn test_move_of_map() {
    reset()
    {
        var m: {u64: Cnt}
        for var i: u64 = 0; i < 40; i += 1 { m.insert(i, Cnt(i)) }
        var before = moved
        var n = m
        ck(moved == before && live() == 40, "moving the map moves no entry")
        var o = n
        ck(moved == before && live() == 40, "moving it again")
    }
    ck(live() == 0 && errors == 0, "map move: no leak, no double destroy")
}

fn test_merge() {
    reset()
    {
        var a: {u64: Cnt}
        var b: {u64: Cnt}
        for var i: u64 = 0; i < 10; i += 1 { a.insert(i, Cnt(i)) }
        for var i: u64 = 5; i < 15; i += 1 { b.insert(i, Cnt(i)) }
        a.merge(b, pick_new)
        ck(a.size() == 15, "merge: union size")
        ck(a[7].v == 7007 && a[2].v == 2 && a[12].v == 12, "merge: resolver result, own and moved values")
        ck(live() == 15, "merge: both inputs of the resolver are destroyed, no entry duplicated")
    }
    ck(live() == 0 && errors == 0, "merge: no leak, no double destroy")
}

fn test_growth() {
    reset()
    {
        var m: {u64: Cnt}
        for var i: u64 = 0; i < 5000; i += 1 { m.insert(i, Cnt(i)) }
        ck(live() == 5000 && made == 5000, "growth through many blocks keeps one object per entry")
        ck(copied == 0, "growth copies nothing")
        m.reserve(100000)
        m.shrink_to_fit()
        ck(live() == 5000, "reserve and shrink_to_fit")
    }
    ck(live() == 0 && errors == 0, "growth: no leak, no double destroy")
}

fn test_counted_keys() {
    reset()
    {
        var m: {Cnt: Cnt}
        for var i: u64 = 0; i < 100; i += 1 { m.insert(Cnt(i), Cnt(i * 2)) }
        ck(live() == 200, "counted keys: a key and a value per entry")
        var *p? = m.get(Cnt(5))
        ck(p? && p->v == 10 && live() == 200, "counted keys: a probe key is destroyed after the lookup")
        var old? = m.insert(Cnt(5), Cnt(55))
        ck(old? && old.v == 10 && live() == 201, "counted keys: the stored key stays, the new key is destroyed")
        old = null
        ck(live() == 200, "counted keys: dropped")
        m.swap_remove(Cnt(3))
        m.shift_remove(Cnt(4))
        ck(m.size() == 98 && live() == 196, "counted keys: removal destroys key and value")
        var c = m.copy()
        ck(live() == 392, "counted keys: copy duplicates keys and values")
    }
    ck(live() == 0 && errors == 0, "counted keys: no leak, no double destroy")
}

fn main() -> i32 {
    test_drop_of_map()
    test_replace_and_remove()
    test_setter()
    test_clear_and_retain()
    test_copy()
    test_move_of_map()
    test_merge()
    test_growth()
    test_counted_keys()
    io::println(f"{checks} checks, {failures} failures")
    return failures as i32
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -f %t.exe %t.o2.exe
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// RUN: %kairo_new %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe | %FileCheck %s
// CHECK-NOT: FAIL
// CHECK: {{[0-9]+}} checks, 0 failures
