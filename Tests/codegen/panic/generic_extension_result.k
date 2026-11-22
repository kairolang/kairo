// A panicking method of a generic extension (`extend <K, V> Pair<K, V>`)
// returns its result at the receiver's arguments: the caller's C++ spells
// `Panic<V *, Taken>` as `Panic<int *, Taken>` for a `Pair<i8, i32>`, the
// extension's parameters read off the receiver, as a generic class's own
// methods are.

struct Taken {
    var at: i32
}

class <K, V> Pair {
    pub var k: K
    pub var v: V
    pub var full: bool = false
    fn Pair(self, k: K, v: V) { self.k = k; self.v = v }
}

extend <K, V> Pair<K, V> {
    pub fn take(self) panic(Taken) -> *V {
        if self.full {
            panic Taken { at: 1 }
        }

        self.full = true
        unsafe {
            return &self.v as unsafe *V as *V
        }
    }

    pub fn value(const self) panic(Taken) -> V {
        if !self.full {
            panic Taken { at: 2 }
        }

        return self.v
    }
}

fn main() -> i32 {
    var p = Pair<i8, i32>(1, 40)
    var bad = 0
    var e = try p.value() catch t: Taken => t.at
    if e != 2 { bad += 1 }
    var *v = try p.take() catch t: Taken => &p.v
    *v += 2
    var w = try p.value() catch t: Taken => -1
    if w != 42 { bad += 2 }
    var s = Pair<string, string>("a", "b")
    var *sv = try s.take() catch t: Taken => &s.k
    if *sv != "b" { bad += 4 }
    return bad
}

// --- lit wiring ---
// RUN: rm -f %t.exe
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
