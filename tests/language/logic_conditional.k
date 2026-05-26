fn main() -> i32 {
    var x = 10;

    if x > 5 {
        print("x is greater than 5");
    } else: // testing both kinds of suite delimiters
        print("x is not greater than 5");

    return 0;
}

/*
--------- do not remove this comment, it is used by the test script to validate the output ---------
// START TEST
x is greater than 5
// END TEST
*/
