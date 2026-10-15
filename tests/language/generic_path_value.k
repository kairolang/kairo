class A { pub var x: i32 = 1; }
class B { pub var y: i32 = 2; }

fn <T> which() -> i32 {
    eval if std::Meta::is_same_as::<T, A> {
        return 1;
    } else if std::Meta::is_same_as::<T, B> {
        return 2;
    } else {
        return 3;
    }
}

fn main() -> i32 {
    print(which::<A>());
    print(which::<B>());
    print(which::<i32>());
    var v: bool = libcxx::is_same_v::<i32, i32>;
    print(v);
    return 0;
}

/*
--------- do not remove this comment, it is used by the test script to validate the output ---------
// START TEST
1
2
3
true
// END TEST
*/
