class Host {
    fn <U> get(self, x: i32) -> i32 { return x + 1; }
}

class <T> User {
    pub var h: *T;
    fn call(self) -> i32 {
        return self.h->get::<i32>(41);
    }
}

fn main() -> i32 {
    var host = Host();
    var u = User::<Host>();
    u.h = &host;
    print(u.call());
    return 0;
}

/*
--------- do not remove this comment, it is used by the test script to validate the output ---------
// START TEST
42
// END TEST
*/
