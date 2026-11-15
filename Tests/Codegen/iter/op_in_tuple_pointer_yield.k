// A user `op in` yielding a tuple of pointers, built per element from the
// stored fields: `(k, *v)` writes the stored value through the yielded
// pointer, `(k, v)` copies, a value element binds the element, and a
// `const` binder reads a mutable object through `op in (const self)`.

class Table {
    var keys: [i32; 3] = [1, 2, 3]
    var vals: [i32; 3] = [10, 20, 30]
    var reads: i32 = 0

    fn op in (self) -> yield (*const i32, *i32) {
        for var i: usize = 0; i < 3; ++i {
            yield (&self.keys[i] as *const i32, &self.vals[i])
        }
    }

    fn op in (const self) -> yield (*const i32, *const i32) {
        for var i: usize = 0; i < 3; ++i {
            yield (&self.keys[i], &self.vals[i])
        }
    }
}

class Tagged {
    var vals: [i32; 2] = [5, 6]

    fn op in (self) -> yield (usize, *i32) {
        for var i: usize = 0; i < 2; ++i {
            yield (i, &self.vals[i])
        }
    }
}

fn main() -> i32 {
    var t = Table()
    for (k, *v) in t {
        *v += k
    }

    // vals are 11, 22, 33.
    var s = 0
    for (k, v) in t {
        // DIAG: op_in_tuple_pointer_yield.k:[[@LINE+1]]:9: warning [SC275W]: this writes to a copy of the element
        v = 0
        s += k
    }

    for (const k, const *v) in t {
        s += k * *v
    }

    // s is 6 + 11 + 44 + 99 = 160.
    const c = t
    for (_, v) in c {
        s += v
    }

    // s is 160 + 66 = 226.
    var g = Tagged()
    for (i, *v) in g {
        *v += i as i32
    }

    for (i, v) in g {
        s += v // 5 + 7
    }

    // A lone `_` counts the entries.
    for _ in t {
        s += 1
    }

    return s - 203 // 38
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not=error --implicit-check-not=warning
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --check-prefix=BUILD --allow-empty --implicit-check-not=error
// BUILD-NOT: C307W
// RUN: %t.exe; test $? -eq 38
