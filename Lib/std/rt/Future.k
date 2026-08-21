fn <T> foo(a: T, t: (i32, i32, i32), p: *(i32, i32), arr: [i32]) {
    var x0 = t.0
    var x1 = t.0.1
    var x2 = (1, 2).0
    var x3 = t.0.field
    var x4 = arr[0].1
    var x5 = (1, 2).0.bar()
    var x6 = p->0
    var x7 = p?.0
    var x8 = p?->0
    var x9 = f(t.0, t.1)
    var xa = t.0 + 1
    var xb = arr[t.0..t.1]
}

fn other() {
    t.0x1
    t.1u8
    t.1_0
    t.4294967296
}

fn <T> foo2(a: T, p: *T, q: *T) {
    var r0 = !a.*p
    var r1 = a.*p + 1
    var r2 = a.*p ^^ 2
    var r3 = a.*p.*q
    var r4 = (a.*p).field
}