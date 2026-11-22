// The two forms of insert-if-absent. `insert_new(k, v)` is null when it
// inserts and hands `v` back when the key is present; `try_insert(k, v)`
// returns the stored value when it inserts and raises KeyExists when the key
// is present. Neither changes a present key's value or place.

import std::io

static FAILS: i32 = 0
static live: i32 = 0

fn ck(ok: bool, what: string) {
    if !ok {
        io::println(f"FAIL {what}")
        FAILS += 1
    }
}

class Obj {
    pub var v: i32
    pub fn Obj(self, v: i32) { self.v = v; live += 1 }
    // A moved-from Obj is finalized too, so the move counts one more.
    @move fn Obj(self, other: Self) { self.v = other.v; live += 1 }
    fn op finally(self) { live -= 1 }
}

fn main() -> i32 {
    var m: {i32: i32} = {}
    var r? = m.insert_new(1, 10)
    ck(!r? && m[1] == 10, "insert_new: a new key inserts and is null")
    r = m.insert_new(1, 99)
    ck(r? && r == 99 && m[1] == 10 && m.size() == 1, "insert_new: a present key hands the value back")

    var *p = try m.try_insert(2, 20) catch e: KeyExists => &m[1]
    ck(*p == 20 && m[2] == 20 && m.size() == 2, "try_insert: a new key returns the stored value")
    *p = 21
    ck(m[2] == 21, "try_insert: the returned pointer is the stored value")

    var raised = false
    try {
        m.try_insert(1, 77)
    } catch e: KeyExists {
        raised = true
    }

    ck(raised && m[1] == 10 && m.size() == 2, "try_insert: a present key raises and keeps its value")
    var msg = ""
    try {
        m.try_insert(2, 0)
    } catch e: KeyExists {
        msg = e.op panic()
    }

    ck(msg == "the key is already present" && m[2] == 21, f"try_insert: the value of a present key stays: {msg}")

    // Order: a refused insert keeps the key's place.
    var t: {string: i32} = {}
    t.insert("a", 1)
    t.insert("b", 2)
    var x = try t.try_insert("a", 5) catch e: KeyExists => &t["b"]
    ck(t.entries()[0].key == "a" && t.entries()[0].value == 1, "try_insert: a refused key keeps its place")
    var *y = try t.try_insert("c", 3) catch e: KeyExists => &t["a"]
    ck(*y == 3 && t.entries()[2].key == "c", "try_insert: a new key appends")

    // A refused value is dropped exactly once; an inserted one stays alive.
    {
        var o: {i32: Obj} = {}
        o.insert(1, Obj(1))
        var stored = 0
        try {
            var *q = o.try_insert(2, Obj(2))
            stored = q->v
        } catch e: KeyExists {
        }

        ck(stored == 2 && live == 2, "try_insert: the inserted object lives in the map")
        var refused = false
        try {
            o.try_insert(1, Obj(3))
        } catch e: KeyExists {
            refused = true
        }

        ck(refused && live == 2 && o[1].v == 1, "try_insert: the refused object is dropped")
        var back? = o.insert_new(2, Obj(4))
        ck(back? && back.v == 4 && o[2].v == 2, "insert_new hands the object back")
    }

    ck(live == 0, f"every object dropped once: {live}")
    var what = KeyExists {}
    ck(what.op panic() == "the key is already present", "KeyExists message")

    io::println(f"done, {FAILS} failures")
    return FAILS
}

// --- lit wiring ---
// RUN: rm -f %t.exe
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// CHECK-NOT: FAIL
// CHECK: done, 0 failures
