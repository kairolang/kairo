// Panicking functions in one file, called from another (app.k). This TU
// lowers first: each function's C++ result (FunctionDecl::panic_result) is
// formed here, and the importer's preamble declares them with it, while its
// typing still reads each call's value type.

pub struct IOError { var code: i32 }
pub struct ParseError { var pos: i32 }

pub fn read(p: i32) panic -> i32 {
    if p < 0 { panic IOError { code: p } }
    return p
}

// Inferred, through a call and a recursion: {IOError, ParseError}.
pub fn parse(s: i32) panic -> i32 {
    if s == 0 { panic ParseError { pos: 0 } }
    if s > 100 { return parse(s - 1) }
    return read(s)
}

pub fn pick(x: i32) panic -> i32 where x > 50 { panic ParseError { pos: x } }
pub fn pick(x: i32) -> i32 { return x }
