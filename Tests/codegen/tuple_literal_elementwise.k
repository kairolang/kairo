// A tuple literal converts element by element where a tuple type is
// expected: each element by the conversion an initialization of that
// element allows. At an initialization, an assignment, a return, a
// yield, an argument (overloaded or not), a nested literal, and in a
// generic class's `op in`.

class Base {
    var b: i32 = 1
}

class Derived derives Base {
    var d: i32 = 2
}

class <K, V> Entry {
    var k: K
    var v: V
    fn Entry(self, k: K, v: V) {
        self.k = k
        self.v = v
    }

    fn op in (self) -> yield (*const K, *V) {
        yield (&self.k, &self.v)
    }
}

fn first(t: (*const i32, *i32)) -> i32 {
    return *t.0
}

fn pick(t: (*const i32, i64)) -> i32 {
    return *t.0 + t.1 as i32
}

fn pick(t: string) -> i32 {
    return 100
}

fn made(a: *i32, b: *i32) -> (*const i32, *i32) {
    return (a, b)
}

fn gen(a: *i32) -> yield (*const i32, i32) {
    yield (a, 1)
}

fn main() -> i32 {
    var a = 1
    var b = 2
    var n: i32 = 4
    // `*i32` variables, so each `*i32` to `*const i32` is the literal's
    // conversion and not an `&x` written where a pointer to const is
    // expected.
    var *pa = &a
    var *pb = &b
    var t: (*const i32, *i32) = (pa, pb);
    *t.1 = 3
    t = (pb, pa)
    var w: (i64, f64) = (n, n)
    var nn: ((*const i32, i64), i32) = ((pa, n), 5)
    var dd = Derived()
    var bp: (*Base, i32?) = (&dd, n)
    var s = *t.0 + *t.1 // 3 + 1
    s += first((pa, pb)) // 1
    s += pick((pa, n)) // 5
    s += *made(&a, &b).0 // 1
    for (k, v) in gen(&b) { // 3 + 1
        s += *k + v
    }

    var e = Entry<i32, i32>(10, 20)
    for (k, *v) in e {
        *v += k
    }

    s += w.0 as i32 + w.1 as i32 // 8
    s += *nn.0.0 + nn.0.1 as i32 + nn.1 // 10
    s += bp.0->b + (bp.1 ?? 0) // 5
    // 4 + 1 + 5 + 1 + 4 + 8 + 10 + 5 = 38, and e.v is 30
    return s - 38 + e.v - 30
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -w -o %t.exe --cache-dir %t.d
// RUN: %t.exe
