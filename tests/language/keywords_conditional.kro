fn main() -> i32 {
    var x: i32 = 10;

    // Test: Simple if-else
    if x > 5 {
        print("x is greater than 5");
    } else {
        print("x is not greater than 5");
    }

    // Test: unless (inverse of if)
    unless x < 5 {
        print("x is not less than 5");
    }

    // Test: match-case (multi-branch conditional)

    /// needs to be implemented
    // match x {
    //     case 5:
    //         print("x is 5");
    //     case 10:
    //         print("x is 10");
    //     default:
    //         print("x is something else");
    // }

    // Test: switch-case
    switch x {
        case 15 {
            print("x is 15");
        } case 10 {
            print("x is 10");
        } default {
            print("x is neither 15 nor 10");
        }
    }

    return 0;
}

// import std::range;

// test "conditional keywords" {
//     var stdout: list<string> = std::io::capture::<std::io::stdout!> {
//         main();
//     };

//     if stdout.len() < 3:
//         return false; // indicates the test impl failed

//     var excepted: list<string> = [
//         "x is greater than 5",
//         "x is not less than 5",
//         "x is 10"
//     ];

//     var foo: int = 19;

//     for i, j in std.zip(stdout, excepted) {
//         if i != j {
//             print(f"excepted {j} but got {i}");
//             return false;
//         }
//     }
// }

// fn <...T> zip(args: ...T) -> (T::underlying_t, ...)
//   requires (T... impl std::ranges::Iterable) -> {

//     var zipped_result: std::Vec<(T::underlying_t?...)>; // [(string, int, ...)]
//     bool has_next = true;

//     while has_next {
//         zipped_result.push((...args.next()));
//     }
// }

/*
--------- do not remove this comment, it is used by the test script to validate the output ---------
// START TEST
x is greater than 5
x is not less than 5
x is 10
// END TEST
*/
