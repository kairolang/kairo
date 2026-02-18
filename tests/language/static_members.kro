interface Multiplex {
    fn complex_method(self) -> i32;
    static fn complex_static_method();
    var complex_field: i32;
}

// A class implementing Multiplex
class Barn impl Multiplex {
    fn complex_method(self) -> i32 {
        return self.complex_field * 2;
    }

    static fn complex_static_method() {
        print("Barn static method");
    }

    pub var complex_field: i32 = 20;
}

fn main() -> i32 {
    // Test Multiplex interface
    var baz_instance = Barn{};
    print(baz_instance.complex_method()); // Should print 40
    Barn::complex_static_method(); // Should print "Barn static method"
    return 0;
}

/*
--------- do not remove this comment, it is used by the test script to validate the output ---------
// START TEST
40
Barn static method
// END TEST
*/
