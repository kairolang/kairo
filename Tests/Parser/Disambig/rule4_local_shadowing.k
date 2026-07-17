// Locals shadow globals in the verdict:
// 1. A local var bound to a GENERIC CLOSURE commits `<` as generic args
//    even though the table knows nothing about it.
// 2. A local param shadowing a global generic fn commits `<` as comparison
//    the lexical binding wins over the table's positive evidence.

fn <T> gen(v: T) -> T {
    return v
}

fn main() -> i32 {
    var f = fn <T> (x: T) -> T {
        return x
    }
    var r = f<i32>(5)
    return 0
}

fn shadowed(gen: i32) -> i32 {
    var a = 1
    var c = gen<a>(10)
    return c
}
