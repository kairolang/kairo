// Basic interface with a generic
interface <U> Foo {
    fn poo(self) -> U;
}

// Interface without generics
interface Basic_Something {
    fn poo(self) -> i32;
}

// A class implementing Foo and Basic_Something
class Drinks impl Foo::<i32>, Basic_Something {
    fn poo(self) -> i32 {
        return self.x;
    }

    static fn bar() {
        print("Drinks");
    }

    var x: i32 = 10;
}

fn main() -> i32 {
    // Test Foo and Basic_Something functionality
    var drink_instance = Drinks{};
    print(drink_instance.poo()); // Should print 10
    Drinks::bar(); // Should print "Drinks"
    return 0;
}

/*
--------- do not remove this comment, it is used by the test script to validate the output ---------
// START TEST
10
Drinks
// END TEST
*/
