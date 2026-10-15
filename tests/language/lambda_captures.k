fn main() -> i32 {
    var count: i32 = 0;
    var bump = fn () |*count| { (*count) += 1; };
    bump();
    bump();
    print(count);

    var x: i32 = 1;
    var read_copy = fn () -> i32 { return x; };
    x = 50;
    print(read_copy());

    var a: i32 = 4;
    var listed = fn () |a| -> i32 { return a + 1; };
    print(listed());

    var none = fn () || -> i32 { return 9; };
    print(none());

    var double = fn (v: i32) -> i32 = v * 2;
    print(double(21));
    var g = fn (v: i32) = v + 1;
    print(g(1));

    var c: i32 = 4;
    var k = fn () |const *c, const a| -> i32 { return (*c) + a; };
    print(k());
    return 0;
}

/*
--------- do not remove this comment, it is used by the test script to validate the output ---------
// START TEST
2
50
5
9
42
2
8
// END TEST
*/
