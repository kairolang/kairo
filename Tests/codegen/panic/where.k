// A `where` group whose members panic (PANIC.md §2.8, where.mdx): the
// dispatcher's set is the union of its members' -- here {Neg, Big} -- each
// candidate returns its own set's result, and the dispatcher forwards it.
struct Neg { var v: i32 }
struct Big { var v: i32 }
fn classify(x: i32) panic -> i32 where x > 100 { panic Big { v: x } }
fn classify(x: i32) panic(Neg) -> i32 where x < 0 { panic Neg { v: x } }
fn classify(x: i32) -> i32 { return x * 2 }
fn main() -> i32 {
    var a = try classify(5) catch => 0
    var b = try classify(-3) catch e: Neg => e.v catch => 0
    var c = try classify(200) catch e: Big => e.v catch => 0
    if a != 10 { return 1 }
    if b != -3 { return 2 }
    if c != 200 { return 3 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
