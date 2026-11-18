// `var m = *a` with a: unsafe *T inside a generic body.
// Expected: m is T, no diagnostic.
// Actual: I011W "internal: 'm' reached codegen with no inferred type; This is
// a compiler bug". The program still runs correctly (exit 2). `var m: T = *a`
// avoids it.
pub interface Less { fn op < (const self, const o: Self) -> bool }
struct P { var k: i64  fn op < (const self, const o: P) -> bool { return self.k < o.k } }

fn <T impl Less> first_min(a: unsafe *T, n: isize) -> T {
    unsafe {
        var m = *a
        for var i: isize = 1; i < n; i += 1 { if *(a + i) < m { m = *(a + i) } }
        return m
    }
}

fn main() -> i32 {
    var buf: [P; 3]
    buf[0] = P { k: 5 }
    buf[1] = P { k: 2 }
    buf[2] = P { k: 9 }
    var r: P = P { k: 0 }
    unsafe { r = first_min<P>(&buf[0] as unsafe *P, 3) }
    return r.k as i32   // exit 2
}
