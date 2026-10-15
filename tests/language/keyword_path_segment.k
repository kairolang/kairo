type Thread = libcxx::thread;

fn main() -> i32 {
    const N: usize = sizeof(libcxx::thread::id);
    print(N > 0);
    var t = Thread(fn () {});
    t.join();
    print("joined");
    return 0;
}

/*
--------- do not remove this comment, it is used by the test script to validate the output ---------
// START TEST
true
joined
// END TEST
*/
