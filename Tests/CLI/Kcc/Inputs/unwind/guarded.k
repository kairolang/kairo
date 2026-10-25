// guarded.k
import std::io::println
ffi "c++" import "thrower.hh"

fn relay(x: i32) -> i32 {
    return checked_double(x) + 1             // no try: a Kairo frame between the throw and the catch
}

pub fn guarded(x: i32) -> i32 {
    try {
        return relay(x)
    } catch e: cxx::std::exception {
        println("  [Kairo] caught C++ exception")
        return -1
    }
}
