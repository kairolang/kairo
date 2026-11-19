// A local deduced from a record's own operator inside its generic body
// (`var d = self - other` in `class <T> Q`) has the operator's declared
// result type, so a member read off it compiles. Unbound, the local had no
// type to declare and the member read reached codegen unresolved.

class <T> Q {
    pub var f: i32 = 0

    fn op - (const self, const other: Q<T>) -> Q<T> {
        var r: Q<T>
        r.f = self.f - other.f
        return r
    }

    fn op == (const self, const other: Q<T>) -> bool {
        return self.f == other.f
    }

    fn gap(const self, const other: Q<T>) -> i32 {
        var d = self - other
        return d.f
    }

    fn same(const self, const other: Q<T>) -> bool {
        var e = self == other
        return e
    }
}

fn main() -> i32 {
    var a: Q<i32>
    var b: Q<i32>
    a.f = 9
    b.f = 4
    if a.gap(b) != 5 {
        return 1
    }

    if a.same(b) || !a.same(a) {
        return 2
    }

    return 0
}

// --- lit wiring ---
// RUN: rm -f %t.exe
// RUN: { %kairo %s -o %t.exe 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty --implicit-check-not='error' --implicit-check-not='internal' --implicit-check-not='warning'
// RUN: %t.exe
// DIAG-NOT: I011W
