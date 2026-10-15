class B { pub var k: i32 = 1; static fn classof(p: const *B) -> bool { return p->k == 1; } }

fn <T> cst(ptr: const *B) -> const *T {
    assert((ptr != &null) && r"cast<>: null pointer");
    return static_cast::<const *T>(ptr);
}

fn <T> cst(ptr: *B) -> *T {
    return static_cast::<*T>(ptr);
}

fn main() -> i32 {
    var b = B();
    var cp: const *B = &b;
    print(cst::<B>(cp)->k);
    print(cst::<B>(&b)->k);
    return 0;
}

/*
--------- do not remove this comment, it is used by the test script to validate the output ---------
// START TEST
1
1
// END TEST
*/
