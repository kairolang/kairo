class P { pub var Desc: i32 = 5; pub var z: i32 = 0; }
fn main() -> i32 {
    var feat = P();
    var x = feat.Desc if (feat.Desc != 0) else 1;
    print(x);
    var y = feat.z if (feat.z != 0) else 1;
    print(y);
    var w = 7 if feat.Desc == 5 else 8;
    print(w);
    return 0;
}

/*
--------- do not remove this comment, it is used by the test script to validate the output ---------
// START TEST
5
1
7
// END TEST
*/
