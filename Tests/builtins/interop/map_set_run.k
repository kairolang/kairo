// `{K: V}` -> `std::unordered_map<K, V>` and `{T}` -> `std::unordered_set<T>`,
// for `i32`, `string` and a move-only key that counts its live objects and
// its moves. `into_cxx()` moves every entry out and leaves the Kairo map or
// set empty; `as` copies each one. The C++ side keeps no insertion order,
// so contents are compared as sets: every entry is found once in the C++
// container and the sizes agree. The way back iterates the C++ container
// into a new map or set. Afterwards no object is left alive.

ffi "c++" import "unordered_map"
ffi "c++" import "unordered_set"

import std::io

var checks:   u64 = 0
var failures: u64 = 0
var live:     i64 = 0
var moves:    i64 = 0

fn ck(cond: bool, const what: string) {
    checks += 1
    if !cond {
        failures += 1
        io::println(f"FAIL {what}")
    }
}

/// Move-only: no copy(), no copy constructor.
class Tok impl Hash {
    pub var id: i64

    pub fn Tok(self, id: i64) {
        self.id = id
        live += 1
    }

    @move pub fn Tok(self, other: Self) {
        self.id  = other.id
        other.id = -1
        live  += 1
        moves += 1
    }

    pub fn op finally(self) {
        live -= 1
    }

    pub fn op == (const self, const o: Tok) -> bool {
        return self.id == o.id
    }

    fn hash(const self, @inout h: Hasher) {
        h.write_usize(self.id as usize)
    }
}

fn same_str(const a: string, const b: string) -> bool {
    return a == b
}

fn dup(const a: string) -> string {
    return a.copy()
}

fn int_map() {
    var m = HashMap<i32, i32>()
    for var i: i32 = 0; i < 500; ++i {
        m[i] = i * 3
    }

    var c = m as cxx::std::unordered_map<i32, i32>
    ck(c.size() == 500 && m.size() == 500, "i32 map as: sizes")
    var same = true
    for (k, v) in m {
        if c.count(k) != 1 || c.at(k) != v {
            same = false
        }
    }

    ck(same, "i32 map as: same entries")
    // COMPILER-WORKAROUND(for-over-generic-return): a `for` over `x` is an
    // internal error unless its type is written.
    var x: cxx::std::unordered_map<i32, i32> = m.into_cxx()
    ck(m.size() == 0 && x.size() == 500, "i32 map into_cxx: sizes")
    var all = true
    for var i: i32 = 0; i < 500; ++i {
        if x.count(i) != 1 || x.at(i) != i * 3 {
            all = false
        }
    }

    ck(all, "i32 map into_cxx: same entries")
    var back = HashMap<i32, i32>()
    for p in x {
        back[p.first] = p.second
    }

    var same_back = back.size() == 500
    for var i: i32 = 0; i < 500; ++i {
        if back[i] != i * 3 {
            same_back = false
        }
    }

    ck(same_back, "i32 map back")
    var e = HashMap<i32, i32>()
    ck(e.into_cxx().size() == 0, "i32 map empty")
}

fn string_map() {
    var m = HashMap<string, string>()
    for var i: i32 = 0; i < 40; ++i {
        m[f"key {i} long enough to live on the heap"] = f"value {i}"
    }

    var c = m as cxx::std::unordered_map<string, string>
    var same = c.size() == 40
    for *e in m.entries() {
        if c.count(e->key) != 1 || c.at(e->key) != e->value {
            same = false
        }
    }

    ck(same, "string map as: same entries")
    var x: cxx::std::unordered_map<string, string> = m.into_cxx()
    ck(m.size() == 0 && x.size() == 40, "string map into_cxx: sizes")
    var all = true
    for var i: i32 = 0; i < 40; ++i {
        var k = f"key {i} long enough to live on the heap"
        if x.count(k.view()) != 1 || !same_str(x.at(k.view()), f"value {i}") {
            all = false
        }
    }

    ck(all, "string map into_cxx: same entries")
    var back = HashMap<string, string>()
    for var i: i32 = 0; i < 40; ++i {
        var k = f"key {i} long enough to live on the heap"
        var v = dup(x.at(k.view()))
        back.insert(k, v)
    }

    ck(back.size() == 40 && back["key 39 long enough to live on the heap"] == "value 39", "string map back")
}

fn tok_map() {
    var m = HashMap<Tok, i64>()
    for var i: i64 = 0; i < 64; ++i {
        m.insert(Tok(i), i * 2)
    }

    ck(live == 64, "tok map: 64 live")
    var before = moves
    var x: cxx::std::unordered_map<Tok, i64> = m.into_cxx()
    ck(moves - before == 64, "tok map into_cxx: one move per key")
    ck(live == 64 && m.size() == 0 && x.size() == 64, "tok map into_cxx: sizes")
    var all = true
    for var i: i64 = 0; i < 64; ++i {
        if x.count(Tok(i)) != 1 || x.at(Tok(i)) != i * 2 {
            all = false
        }
    }

    ck(all, "tok map into_cxx: same entries")
}

fn sets() {
    var s = HashSet<i32>()
    for var i: i32 = 0; i < 300; ++i {
        s.insert(i * 5)
    }

    var c = s as cxx::std::unordered_set<i32>
    var same = c.size() == 300
    for x in s {
        if c.count(x) != 1 {
            same = false
        }
    }

    ck(same, "i32 set as: same elements")
    var x: cxx::std::unordered_set<i32> = s.into_cxx() // COMPILER-WORKAROUND(for-over-generic-return)
    var all = s.size() == 0 && x.size() == 300
    for var i: i32 = 0; i < 300; ++i {
        if x.count(i * 5) != 1 {
            all = false
        }
    }

    ck(all, "i32 set into_cxx")
    var back = HashSet<i32>()
    for p in x {
        back.insert(p)
    }

    ck(back.size() == 300 && (299 * 5) in back, "i32 set back")

    var t = HashSet<string>()
    t.insert("a")
    t.insert("a string that is long enough to be owned")
    var tc = t as cxx::std::unordered_set<string>
    ck(tc.size() == 2 && tc.count("a") == 1, "string set as")
    var tx = t.into_cxx()
    ck(t.size() == 0 && tx.size() == 2 && tx.count("a string that is long enough to be owned") == 1, "string set into_cxx")

    var k = HashSet<Tok>()
    for var i: i64 = 0; i < 20; ++i {
        k.insert(Tok(i))
    }

    var before = moves
    var kx: cxx::std::unordered_set<Tok> = k.into_cxx()
    ck(moves - before == 20, "tok set into_cxx: one move per element")
    var kall = k.size() == 0 && kx.size() == 20
    for var i: i64 = 0; i < 20; ++i {
        if kx.count(Tok(i)) != 1 {
            kall = false
        }
    }

    ck(kall, "tok set into_cxx")
}

fn main() -> i32 {
    // COMPILER-WORKAROUND(witness-unused-bound): `as` needs the `Copyable`
    // witness of each element type, which clang is given only when the unit
    // copies a value of that type through the bound (as_witness_alone_run.k).
    var w1: i32 = copy(1)
    var w2 = copy("w")
    ck(w1 == 1 && w2 == "w", "witness triggers")
    int_map()
    string_map()
    tok_map()
    sets()
    ck(live == 0, "no object left")
    io::println(f"map/set interop: checks={checks} failures={failures} live={live}")
    return failures as i32
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// RUN: %kairo -O2 %s -o %t.o2.exe --cache-dir %t.d2
// RUN: %t.o2.exe | %FileCheck %s --match-full-lines
// CHECK: map/set interop: checks=23 failures=0 live=0
