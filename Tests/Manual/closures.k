var add = fn (a: i32, b: i32) -> i32 {
    return a + b
}

var double = fn (x: i32) -> i32 {
    return x * 2
}

add(3, 4)     // 7
double(10)    // 20

var opr: fn(i32, i32) -> i32 = fn (a: i32, b: i32) -> i32 { return a + b }

var x = 10
var add_x = fn (y: i32) -> i32 {
    return y + x   // x is captured by copy
}

x = 999
add_x(5)   // 15 uses the copied value of x (10), not 999

var count = 0
var increment = fn ()|&| {
    count += 1   // modifies the original count
}

increment()
increment()
count   // 2

var a = 10
var b = 20

var closure = fn (x: i32)|a, &b| -> i32 {
    b += 1       // modifies the original b
    return x + a + b   // a is a copy, b is a reference
}

closure(5)   // 5 + 10 + 21 = 36
a            // still 10
b            // 21

var greet = fn (name: string = "world") {
    std::println(f"Hello, {name}!")
}

greet()          // "Hello, world!"
greet("Alice")   // "Hello, Alice!"

var identity = fn <T>(x: T) -> T {
    return x
}

identity(42)        // i32
identity("hello")   // string

var risky = fn () panic -> i32 {
    if bad_condition {
        panic std::Error::Runtime("failed")
    }
    return 42
}

try {
    risky()
} catch e {
    std::println(f"Caught: {e}")
}

fn make_closure() -> fn() -> i32 {
    var x = 42
    return fn ()|&x| -> i32 { return x }
    // AMT error: x is a stack local, closure would outlive it,
    //   and there is no safe promotion path for a stack variable
}

fn make_closure() -> fn() -> i32 {
    var x = 42
    return fn () -> i32 { return x }   // ok x is copied into the closure
}

fn outer() -> i32 {
    var x = 10

    fn inner(y: i32) -> i32 = y + 1     // cannot access x inner is a plain function
    // fn inner(y: i32) -> i32 = y + x  // compile error: x is not in scope

    return inner(x)   // pass x explicitly
}

fn apply(f: fn(i32) -> i32, x: i32) -> i32 {
    return f(x)
}

apply(fn (x: i32) -> i32 { return x * 2 }, 21)   // 42

var triple = fn (x: i32) -> i32 { return x * 3 }
apply(triple, 10)   // 30

fn map(data: [i32], transform: fn(i32) -> i32) -> [i32] {
    var result: [i32]
    for item in data {
        result.push(transform(item))
    }
    return result
}

var doubled = map([1, 2, 3], fn (x: i32) -> i32 { return x * 2 })
// doubled == [2, 4, 6]