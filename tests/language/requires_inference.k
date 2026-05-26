fn <T> add(a: T, b: T) -> T {
    return a + b;
}

fn main() -> i32 {
    var result = add(10, 20);
    print(result);
    return 0;
}

/*
--------- do not remove this comment, it is used by the test script to validate the output ---------
// START TEST
30
// END TEST
*/
