// Basic interface with a generic
interface <U> Haggle {
    fn tia(self) -> U;
}

// Invalid class with mismatched return type
class InvalidC impl Haggler::<string> {
    fn tia(self) -> i64 { // Mismatched return type
        return 0;
    }
}

// Invalid class missing required method
class MissingMethodC impl Haggler::<i32> {
    // Missing `fn tia(self) -> i32`
}

fn <T> tia() requires T impl Haggler::<i32> { // function must be defined so the check is done
    var instance: T;
    print(instance.tia());
}

fn main() -> i32 {
    return 0;
}

/*
| windows vvvv
error: C2338: static_assert failed: 'InvalidC must satisfy Haggler interface'
| windows vvvv
error: C2338: static_assert failed: 'MissingMethodC must satisfy Haggler interface'

--------- do not remove this comment, it is used by the test script to validate the output ---------
// START ERRORS
error: static assertion failed: InvalidC must satisfy Haggler interface
error: static assertion failed: MissingMethodC must satisfy Haggler interface
// END ERRORS
*/
