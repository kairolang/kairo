// `.Variant` as an operand takes its enum from the other side: the right
// operand of `==` / `!=` and the right side of an assignment are typed
// against the left one's type. A dotted LEFT operand (`.South == d`) takes
// the right one's the same way; dotted_left_operand.k and dotted_left_xmod/
// pin it.

enum Dir { North, South, East }
enum Level { Info, Error, Fatal }
enum Opt { None, Some { v: i32 } }

fn severe(l: Level) -> bool { return l == .Error || l == .Fatal; }

fn main() -> i32 {
    var r = 0;
    var d: Dir = .North;
    if d == .North { r = r + 1; }
    if d != .South { r = r + 2; }
    d = .South;
    if d == .South { r = r + 4; }
    if severe(Level::Fatal) { r = r + 8; }
    if !severe(Level::Info) { r = r + 16; }
    var o: Opt = .None;
    if o == .None { r = r + 32; }
    o = .Some { v: 3 };
    if o != .None { r = r + 64; }
    return r;   // 127
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 127
