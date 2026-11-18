// A record's own operators used on the record inside its generic body stay
// deferred to the instance for every operator form, never an internal error:
// a comparison operator, a unary operator and an operator called through a
// local of the instance type.

class <T> Q {
    pub var f: i32 = 0
    fn op < (const self, const other: Q<T>) -> bool { return self.f < other.f }
    fn op > (const self, const other: Q<T>) -> bool { return other < self }
    fn op - (const self, const other: Q<T>) -> Q<T> {
        var r: Q<T>
        r.f = self.f - other.f
        return r
    }
    fn gap(const self, const other: Q<T>) -> i32 {
        var d: Q<T> = self - other
        if d > self { return 100 }
        return d.f
    }
}

fn main() -> i32 {
    var a: Q<i32>
    var b: Q<i32>
    a.f = 9
    b.f = 4
    if !(b < a) { return 1 }
    if !(a > b) { return 2 }
    if a.gap(b) != 5 { return 3 }
    return 0
}

// --- lit wiring ---
// RUN: rm -f %t.exe && rm -rf %t.d
// RUN: { %kairo %s -o %t.exe --cache-dir %t.d 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty --implicit-check-not='I003E' --implicit-check-not='internal'
// RUN: %t.exe
// DIAG-NOT: error
