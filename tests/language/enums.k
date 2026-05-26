// anonymous enum
struct S {
    enum {
        A,
        B,
        C
    }
}

fn main() -> i32 {
    var s = S::A;
    var t = S::B;
    var u = S::C;

    print(f"{s}, {t}, {u}");
    
    return 0;
}
/*
--------- do not remove this comment, it is used by the test script to validate the output ---------
// START TEST
0, 1, 2
// END TEST
*/