ffi "c++" import "cstdlib";

class Env {
    fn getenv(self, name: *std::Legacy::char) -> i32 { return 7; }

    fn probe(self) -> bool {
        // `::getenv` must reach the C global, not this member
        return ::getenv(r"KAIRO_SURELY_UNSET_VAR_9F2") == &null;
    }
}

fn main() -> i32 {
    var e = Env();
    print(e.probe());
    print(e.getenv(r"x"));
    return 0;
}

/*
--------- do not remove this comment, it is used by the test script to validate the output ---------
// START TEST
true
7
// END TEST
*/
