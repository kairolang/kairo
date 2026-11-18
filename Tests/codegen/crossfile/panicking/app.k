import lib::*

fn twice(s: i32) panic -> i32 { return parse(s) + parse(s) }

fn main() -> i32 {
    if (try parse(5) catch => 0) != 5 { return 1 }
    if (try parse(0) catch e: ParseError => 10 + e.pos catch => 0) != 10 { return 2 }
    if (try twice(-3) catch e: IOError => e.code catch => 0) != -3 { return 3 }
    if (try parse(103) catch => 0) != 100 { return 4 }
    if (try pick(60) catch e: ParseError => e.pos) != 60 { return 5 }
    if (try pick(6) catch e: ParseError => e.pos) != 6 { return 6 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
