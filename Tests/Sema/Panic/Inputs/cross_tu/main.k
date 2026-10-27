import lib
import broken

// Handles one of lib::parse's two inferred types and declares nothing:
// ParseError is unhandled here.
fn partial(s: i32) -> i32 {
    try { return lib::parse(s) } catch e: lib::IOError { return 0 }
}

// The inferred set is exactly what is declared here: no error.
fn exact(s: i32) panic(lib::IOError, lib::ParseError) -> i32 {
    return lib::parse(s)
}

fn main() -> i32 {
    var a = lib::safe(3)        // the library handled it: nothing to do
    var b = broken::shaky()     // unknown set: nothing said
    return a + b + partial(1)
}
