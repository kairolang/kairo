enum Kind derives u8 { A, B, COUNT, }
const TOTAL: u8 = static_cast::<u8>(Kind::COUNT);
type Count = u8;

fn main() -> i32 {
    const N: i32 = 4;
    type Local = i32;
    var c: Count = TOTAL;
    var l: Local = N;
    print(i32(c) + l);
    return 0;
}

/*
--------- do not remove this comment, it is used by the test script to validate the output ---------
// START TEST
6
// END TEST
*/
