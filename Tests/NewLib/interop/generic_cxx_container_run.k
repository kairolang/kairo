// C++ containers in generic code and as a conditional extension member's
// return type kept in a deduced local:
// - a usize handed to a member of an instance over the generic's own
//   parameters (`reserve(n)` on `unordered_map<K, V>`) goes as it is: the
//   parameter's `size_type` is spelled only by the C++ template's own
//   parameters, so C++ converts it;
// - `for` over `m.into_cxx()` iterates the C++ map;
// - `move(*(d + i))` through `c.data()` of `v.into_cxx()` moves.

ffi "c++" import "unordered_map"
ffi "c++" import "vector"

class Tok {
    pub var id: i64

    pub fn Tok(self, id: i64) {
        self.id = id
    }

    @move pub fn Tok(self, other: Self) {
        self.id  = other.id
        other.id = -1
    }
}

fn <K, V> make(n: usize) -> cxx::std::unordered_map<K, V> {
    var out = cxx::std::unordered_map<K, V>()
    out.reserve(n)
    return out
}

fn main() -> i32 {
    var r = make<i32, i32>(10)
    var bad = 0
    if r.bucket_count() < 10 {
        bad += 1
    }

    var m = HashMap<i32, i32>()
    m.insert(1, 2)
    m.insert(3, 4)
    var x = m.into_cxx()
    var t = 0
    for p in x {
        t += p.second
    }

    if t != 6 {
        bad += 2
    }

    var v = Vector<Tok>()
    v.push(Tok(7))
    v.push(Tok(8))
    var c = v.into_cxx()
    var back = Vector<Tok>()
    unsafe {
        var unsafe *d = c.data() as unsafe *Tok
        for var i: usize = 0; i < c.size(); ++i {
            back.push(move(*(d + i)))
        }
    }

    if back.size() != 2 || back[1].id != 8 {
        bad += 4
    }

    return bad
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
