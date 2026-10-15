class <T> Foo {
    pub static fn make() -> i32 { return 3; }
    class <U> Inner {
        pub static fn <B> get() -> i32 { return 11; }
    }
    class Plain {
        pub var x: i32 = 5;
    }
}

fn <T> pick() -> i32 {
    var p: typename!(Foo::<T>::Plain);
    return p.x;
}

fn main() -> i32 {
    print(Foo::<i32>::make());
    print(Foo::<i32>::Inner::<u8>::get::<bool>());
    var v: Foo::<i32>::Plain = Foo::<i32>::Plain();
    print(v.x);
    print(pick::<i32>());
    return 0;
}

/*
--------- do not remove this comment, it is used by the test script to validate the output ---------
// START TEST
3
11
5
5
// END TEST
*/
