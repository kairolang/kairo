// Construction: the empty vector, a literal, with_capacity, with_len, filled,
// from_slice, copy, from_iter with exact, short and lg size hints, move
// construction and move assignment, and vectors of vectors, on i32, string
// and the counting classes Counted (moved element by element) and RCounted
// (moved as bytes). Every case with the counting classes ends by checking
// that each object made was destroyed once.
//
// Cases from libc++ test/std/containers/sequences/vector/vector.cons/
// Cases from Rust library/alloctests/tests/vec.rs
//
// Documented rules the expectations rest on (the Vector's library
// documentation): `copy()`, `filled`, `from_slice` allocate exactly their
// length; moving a vector is a bitwise move that leaves no element moved.

import self::inputs::counted::*

/// Counts up `lo`..`hi` as E::make values.
class <E impl Elem> Gen {
    var lo: i64
    var hi: i64

    pub fn Gen(self, lo: i64, hi: i64) {
        self.lo = lo
        self.hi = hi
    }
}

extend <E impl Elem> Gen<E> impl Iterator {
    type Item = E
    fn next(self) -> E? {
        if self.lo == self.hi {
            return null
        }

        self.lo += 1
        return E::make(self.lo - 1)
    }
}

fn <E impl Elem> empty_vector(const tag: string) {
    reset()
    {
        var v: [E]
        expect(v.size() == 0 && v.is_empty(), f"{tag}: empty size")
        expect(v.capacity() == 0, f"{tag}: empty capacity is 0")
        var p = v.pop()
        expect(!p?, f"{tag}: pop of empty is null")
        var f? = v.first()
        expect(!f?, f"{tag}: first of empty is null")
        var l? = v.last()
        expect(!l?, f"{tag}: last of empty is null")
        var d = Vector<E>()
        expect(d.size() == 0 && d.capacity() == 0, f"{tag}: Vector() is empty")
    }

    expect_clean(f"{tag}: empty")
}

fn <E impl Elem> literal(const tag: string) {
    reset()
    {
        var v: [E] = [E::make(5), E::make(6), E::make(7)]
        expect(keys_are(v, [5, 6, 7]), f"{tag}: literal keys")
        expect(v.size() == 3, f"{tag}: literal size")
        var one: [E] = [E::make(9)]
        expect(keys_are(one, [9]), f"{tag}: one-element literal")
        var none: [E] = []
        expect(none.is_empty(), f"{tag}: empty literal")
    }

    expect_clean(f"{tag}: literal")
    expect(COPIES == 0, f"{tag}: a literal moves its elements in, no copies")
}

fn <E impl Elem> with_capacity_cases(const tag: string) {
    reset()
    {
        var z = Vector<E>::with_capacity(0)
        expect(z.size() == 0 && z.capacity() == 0, f"{tag}: with_capacity(0)")
        var v = Vector<E>::with_capacity(10)
        expect(v.size() == 0 && v.is_empty(), f"{tag}: with_capacity makes no elements")
        expect(v.capacity() >= 10, f"{tag}: with_capacity(10) capacity")
        var c = v.capacity()
        for var i: i64 = 0; i < 10; ++i {
            v.push(E::make(i))
        }

        expect(v.capacity() == c, f"{tag}: filling to the capacity does not reallocate")
        expect(keys_are(v, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]), f"{tag}: contents after filling")
        v.push(E::make(10))
        expect(v.capacity() > c, f"{tag}: one past the capacity grows")
        expect(v.size() == 11 && v[10].key() == 10 && v[0].key() == 0, f"{tag}: contents after growing")
    }

    expect_clean(f"{tag}: with_capacity")
}

fn <E impl Elem> with_len_cases(const tag: string, zero: i64) requires E impl Default {
    reset()
    {
        var v = Vector<E>::with_len(5)
        expect(v.size() == 5, f"{tag}: with_len size")
        var all = true
        for var i: usize = 0; i < 5; ++i {
            if v[i].key() != zero {
                all = false
            }
        }

        expect(all, f"{tag}: with_len elements are the default")
        var none = Vector<E>::with_len(0)
        expect(none.is_empty() && none.capacity() == 0, f"{tag}: with_len(0)")
    }

    expect_clean(f"{tag}: with_len")
}

fn <E impl Elem> copies(const tag: string) requires E impl Copyable {
    reset()
    {
        var a = fill<E>(6)
        var b = a.copy()
        expect(keys_are(b, [0, 1, 2, 3, 4, 5]), f"{tag}: copy keys")
        expect(b.capacity() == 6, f"{tag}: copy allocates its length")
        expect(a.data() != b.data(), f"{tag}: copy is a separate block")
        b.push(E::make(6))
        expect(a.size() == 6 && b.size() == 7, f"{tag}: pushing to the copy leaves the source")
        a.truncate(2)
        expect(keys_are(b, [0, 1, 2, 3, 4, 5, 6]), f"{tag}: truncating the source leaves the copy")
        var e: [E]
        var ec = e.copy()
        expect(ec.is_empty() && ec.capacity() == 0, f"{tag}: copy of empty")
        var one = fill<E>(1)
        var oc = one.copy()
        expect(keys_are(oc, [0]) && oc.capacity() == 1, f"{tag}: copy of one")
    }

    expect_clean(f"{tag}: copy")
}

fn <E impl Elem> copy_counts() requires E impl Copyable {
    reset()
    {
        var a = fill<E>(8)
        var b = a.copy()
        expect(COPIES == 8, "copy copies each element once")
        expect(LIVE == 16, "copy leaves both vectors live")
    }

    expect_clean("copy counts")
}

fn <E impl Elem> filled_and_slice(const tag: string) requires E impl Copyable {
    reset()
    {
        var f = Vector<E>::filled(4, E::make(8))
        expect(keys_are(f, [8, 8, 8, 8]), f"{tag}: filled keys")
        expect(f.capacity() == 4, f"{tag}: filled allocates its length")
        var f0 = Vector<E>::filled(0, E::make(1))
        expect(f0.is_empty() && f0.capacity() == 0, f"{tag}: filled(0)")
        var f1 = Vector<E>::filled(1, E::make(2))
        expect(keys_are(f1, [2]), f"{tag}: filled(1)")
        var src = fill<E>(5)
        var s = Vector<E>::from_slice(src[1..4])
        expect(keys_are(s, [1, 2, 3]) && s.capacity() == 3, f"{tag}: from_slice of a middle range")
        var emp = Vector<E>::from_slice(src[2..2])
        expect(emp.is_empty() && emp.capacity() == 0, f"{tag}: from_slice of an empty range")
        expect(keys_are(src, [0, 1, 2, 3, 4]), f"{tag}: from_slice leaves its source")
    }

    expect_clean(f"{tag}: filled and from_slice")
}

fn <E impl Elem> from_iter_hints(const tag: string) {
    reset()
    {
        var exact = Vector<E>::from_iter(Gen<E>(0, 6), 6)
        expect(keys_are(exact, [0, 1, 2, 3, 4, 5]), f"{tag}: from_iter exact hint")
        expect(exact.capacity() == grown_cap<E>(6), f"{tag}: an exact hint allocates once, at the growth minimum")
        var small = Vector<E>::from_iter(Gen<E>(0, 40), 3)
        expect(small.size() == 40 && small[39].key() == 39 && small[0].key() == 0, f"{tag}: from_iter with a short hint")
        var big = Vector<E>::from_iter(Gen<E>(0, 3), 1000)
        expect(keys_are(big, [0, 1, 2]), f"{tag}: from_iter with a lg hint")
        var zero = Vector<E>::from_iter(Gen<E>(0, 5), 0)
        expect(keys_are(zero, [0, 1, 2, 3, 4]), f"{tag}: from_iter with hint 0")
        var none = Vector<E>::from_iter(Gen<E>(3, 3), 0)
        expect(none.is_empty(), f"{tag}: from_iter of nothing")
        var one = Vector<E>::from_iter(Gen<E>(7, 8), 1)
        expect(keys_are(one, [7]), f"{tag}: from_iter of one")
    }

    expect_clean(f"{tag}: from_iter")
}

fn <E impl Elem> moves(const tag: string, counted: bool) {
    reset()
    {
        var a = fill<E>(5)
        var pa = a.data()
        var made = MOVES
        var b = move(a)
        expect(keys_are(b, [0, 1, 2, 3, 4]), f"{tag}: move construction keeps the elements")
        expect(b.data() == pa, f"{tag}: move construction keeps the block")
        expect(MOVES == made && COPIES == 0, f"{tag}: move construction moves no element")
        var c: [E] = fill<E>(3)
        var d = fill<E>(2)
        var live = LIVE
        c = move(d)
        expect(keys_are(c, [0, 1]), f"{tag}: move assignment takes the elements")
        if counted {
            expect(LIVE == live - 3, f"{tag}: move assignment destroys the old elements")
        }
        var e: [E]
        c = move(e)
        expect(c.is_empty(), f"{tag}: move assignment from an empty vector")
        if counted {
            expect(LIVE == live - 5, f"{tag}: move assignment from an empty vector frees the rest")
        }
    }

    expect_clean(f"{tag}: moves")
}

fn <E impl Elem> nested(const tag: string) {
    reset()
    {
        var vv: [[E]]
        for var i: i64 = 0; i < 4; ++i {
            vv.push(fill<E>(i))
        }

        expect(vv.size() == 4, f"{tag}: outer size")
        expect(vv[0].is_empty() && vv[3].size() == 3 && vv[3][2].key() == 2, f"{tag}: inner vectors")
        var inner = vv.remove(1)
        expect(keys_are(inner, [0]), f"{tag}: remove returns the inner vector")
        expect(vv.size() == 3 && vv[1].size() == 2, f"{tag}: outer after remove")
        vv.insert(0, fill<E>(5))
        expect(vv[0].size() == 5 && vv[1].size() == 0, f"{tag}: insert of a vector")
        for var i: usize = 0; i < 40; ++i {
            vv.push(fill<E>(2))
        }

        expect(vv.size() == 44 && vv[0].size() == 5 && vv[43].size() == 2, f"{tag}: growth moves the inner vectors")
    }

    expect_clean(f"{tag}: nested")
}

fn strings() {
    var a: [string] = ["alpha", "beta", ""]
    expect(a.size() == 3 && a[0] == "alpha" && a[2].is_empty(), "string literal")
    var b = a.copy()
    b[0] = "changed"
    expect(a[0] == "alpha" && b[0] == "changed", "string copy is deep")
    var f = Vector<string>::filled(3, "x")
    expect(f.size() == 3 && f[2] == "x", "string filled")
    var w = Vector<string>::with_len(2)
    expect(w.size() == 2 && w[1].is_empty(), "string with_len is empty strings")
    var lg = Vector<string>::filled(2, "a string longer than any inline buffer could be")
    var lc = lg.copy()
    expect(lc[1] == lg[1], "long string copy has the same text")
    lc[0] = "z"
    expect(lg[0] == "a string longer than any inline buffer could be" && lc[0] == "z", "changing a copied string leaves the source")
}

fn main() -> i32 {
    empty_vector<i32>("i32")
    empty_vector<string>("string")
    empty_vector<Counted>("Counted")
    empty_vector<RCounted>("RCounted")
    literal<i32>("i32")
    literal<string>("string")
    literal<Counted>("Counted")
    literal<RCounted>("RCounted")
    with_capacity_cases<i32>("i32")
    with_capacity_cases<string>("string")
    with_capacity_cases<Counted>("Counted")
    with_capacity_cases<RCounted>("RCounted")
    with_len_cases<i32>("i32", 0)
    with_len_cases<string>("string", 0)
    with_len_cases<Counted>("Counted", 0)
    with_len_cases<RCounted>("RCounted", 0)
    copies<i32>("i32")
    copies<string>("string")
    copies<Counted>("Counted")
    copies<RCounted>("RCounted")
    copy_counts<Counted>()
    copy_counts<RCounted>()
    filled_and_slice<i32>("i32")
    filled_and_slice<string>("string")
    filled_and_slice<Counted>("Counted")
    filled_and_slice<RCounted>("RCounted")
    from_iter_hints<i32>("i32")
    from_iter_hints<string>("string")
    from_iter_hints<Counted>("Counted")
    from_iter_hints<RCounted>("RCounted")
    moves<i32>("i32", false)
    moves<string>("string", false)
    moves<Counted>("Counted", true)
    moves<RCounted>("RCounted", true)
    nested<i32>("i32")
    nested<string>("string")
    nested<Counted>("Counted")
    nested<RCounted>("RCounted")
    strings()
    return finish()
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: rm -f %t.exe %t.o2.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe
