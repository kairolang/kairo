ffi "c++" import "math.h";

fn main() -> i32 {
    var result: f32 = sqrt(17.0);
    print(result);

    return 0;
}

/*

Foo<int> foo = new Foo<int>(1);
// what are we parsing?
// 1 Big BinaryExpr. (((Foo < int) > foo) = ((new Foo) < (int > (1))));
// 2 BinaryExpr with a GenericExpr. (((Foo < int) > foo) = new Foo<int>(1);
// 3 GenericExpr with a BinaryExpr. Foo<int> foo = ((new Foo) < (int > (1))));
// 4 GenericExpr assigned to a GenericExpr. Foo<int> foo = new Foo<int>(1);

// we are parsing .4 how do we know this? we need to have a context aware parser

*/

/*
--------- do not remove this comment, it is used by the test script to validate the output ---------
// START TEST
4.12311
// END TEST
*/