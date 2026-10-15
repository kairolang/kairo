fn main() -> i32 {
    var s = "héllo";
    print(s.size());
    print(s[1] == 0xC3);
    print(s);
    return 0;
}

/*
--------- do not remove this comment, it is used by the test script to validate the output ---------
// START TEST
6
true
héllo
// END TEST
*/
