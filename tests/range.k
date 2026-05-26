//===----------------------------------------- Kairo -----------------------------------------====//
//                                                                                                //
//  Part of the Kairo Project, under the Attribution 4.0 International license (CC BY 4.0).       //
//  You are allowed to use, modify, redistribute, and create derivative works, even for           //
//  commercial purposes, provided that you give appropriate credit, and indicate if changes       //
//   were made. For more information, please visit: https://creativecommons.org/licenses/by/4.0/  //
//                                                                                                //
//  SPDX-License-Identifier: Apache-2.0                                                           //
//  Copyright (c) 2024 (CC BY 4.0)                                                                //
//                                                                                                //
//====----------------------------------------------------------------------------------------====//
//                                                                                                //
// \brief This is the range module, it provides a range generator class that can be used to       //
//        generate ranges of any type that can be iterated over.                                  //
//                                                                                                //
//====----------------------------------------------------------------------------------------====//

/// usage:
///
/// import range;
///
/// for i in range(0, 10) {
///     print(i);
/// }
///
/// for i in range('a', 'z') {
///     print(i);
/// }
///
/// op's in class defs need to ignore self parm and work without self while calling as well.

// interface Incrementable {
//     fn op ++ (self)[inc] -> Self;
//     fn op < (self, other: Self)[lt] -> bool;
//     fn op == (self, other: Self)[eq] -> bool;
// }

module some_namespace {
    class <T> Foo {
        fn Foo(self) {
            print("Foo");
        }
    }

    type Bar = i32;
}

fn <T> range(start: T, end: T, step: T = 1) -> yield T {
    while start < end {
        yield start;
        start += step;
    }
}

class SomeBad {
    priv var start: i32;
    priv var end: i32;

    fn SomeBad(self) {
        self.start = 0;
        self.end = 10;
    }

    fn iter(self) -> yield i32 {
        var i = self.start;
        
        while i < self.end {
            yield i++;
        }
    }
}

fn <T> range(end: T) -> yield T {
    var start = T();

    while start < end {
        yield start;
        ++start;
    }
}

fn multi_iter() -> yield (i32, f64) {
    yield (1, 1.0);
    yield (2, 2.0);
    yield (3, 3.0);
}
// find closest if either left or right is the same then take right
fn main() -> i32 {
    var start = libcxx::chrono::high_resolution_clock::now();
    
    finally {
        var end = libcxx::chrono::high_resolution_clock::now();
        var duration = libcxx::chrono::duration_cast::<libcxx::chrono::nanoseconds>(end - start).count();
        print(f"Time taken: {duration}ns");
    }

    var some_a: *SomeBad = malloc(sizeof(SomeBad)) as unsafe *SomeBad;
    finally {
        print("freeing some_a");
        free(some_a as unsafe *void);
    }

    var foo: some_namespace::Foo::<some_namespace::Bar> = some_namespace::Foo::<some_namespace::Bar>();

    finally {
        print("Finally block 2");
        print("This is the end of the program 2");
    }

    print(add(1, "2"));

    for i in some_a->iter() {
        print(i);
    }

    var iter = range::<i32>(0, 10, 9);

    print(f"Iterating over range(0, 10): {next(iter)}");
    print(f"Iterating over range(0, 10): {next(iter)}");
    
    for i in range(0, 10) {
        print(i);
    }

    var a = 0;
    var b = 10;

    for i in range(a, b) {
        print(i);
    }

    for i, y in multi_iter():
        print(f"i = {i}, y = {y}");

    for i in range('a', 'z'):
        print(f"i = {(i - 19) as char}");

    return 0;
}

// grantee that a..b becomes range(a, b); and a..=b becomes range(a, b++);
// a and b must implement Incrementable and be Equatable