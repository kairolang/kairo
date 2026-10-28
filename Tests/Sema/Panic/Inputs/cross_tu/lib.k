// A library whose panic sets are INFERRED. Its TU is typed and solved
// before main.k, which imports it, reads them.

pub struct IOError { var code: i32 }
pub struct ParseError { var pos: i32 }

pub fn read(p: i32) panic -> i32 {
    if p < 0 { panic IOError { code: p } }
    return p
}

// The set reaches across two calls and a recursion: {IOError, ParseError}.
pub fn parse(s: i32) panic -> i32 {
    if s == 0 { panic ParseError { pos: 0 } }
    if s > 100 { return parse(s - 1) }
    return read(s)
}

// Everything handled here: the set is empty, and so a call is no panic.
pub fn safe(s: i32) -> i32 {
    try { return parse(s) } catch { return -1 }
}
