// Every panic is handled or propagated (PANIC.md §2.1, §2.3). A function
// with no `panic` specifier lets nothing leave: a call whose callee's set
// is not discharged by the `try` arms around it, or a `panic` statement,
// is an error naming every unhandled type, with two edits -- mark the
// function `panic`, or (for a call) handle it there. A call is anything X
// resolved to a function: a plain call, a method, a constructor, a user
// operator. An inferred set (bare `panic`) is the union of what the body
// raises and what its callees leave; it reaches through a recursion.

struct IOError { var code: i32 }
struct ParseError { var pos: i32 }

fn read_file(p: i32) panic(IOError) -> i32 {
    if p < 0 { panic IOError { code: p } }
    return p
}

// Inferred: {IOError, ParseError}, the recursion included.
fn parse(s: i32) panic -> i32 {
    if s == 0 { panic ParseError { pos: 0 } }
    if s > 100 { return parse(s - 1) }
    return read_file(s)
}

fn propagates_nothing(x: i32) -> i32 {
    return parse(x)
}

fn raises(x: i32) -> i32 {
    if x < 0 { panic IOError { code: x } }
    return x
}

// One arm short: ParseError is left.
fn partial(x: i32) -> i32 {
    try {
        return parse(x)
    } catch e: IOError {
        return 1
    }
}

// Every type caught, or the bare catch takes the rest: accepted.
fn all_arms(x: i32) -> i32 {
    try {
        return parse(x)
    } catch e: IOError {
        return 1
    } catch e: ParseError {
        return 2
    }
}

fn bare_catch(x: i32) -> i32 {
    var v = try parse(x) catch => 0
    return v
}

// A panic inside an arm is outside its `try`: a sibling arm never sees it.
fn panics_in_arm(x: i32) -> i32 {
    try {
        return read_file(x)
    } catch e: IOError {
        return parse(x)
    } catch e: ParseError {
        return 2
    }
}

// Inner arms discharge first; what is left reaches the outer `try`.
fn nested(x: i32) -> i32 {
    try {
        try {
            return parse(x)
        } catch e: ParseError {
            return 1
        }
    } catch e: IOError {
        return 2
    }
}

class Port {
    var n: i32
    static fn make(n: i32) panic(ParseError) -> Port {
        if n < 0 { panic ParseError { pos: n } }
        return Port(n) }
    fn Port(self, n: i32) { self.n = n }
    fn op + (self, o: Port) panic(IOError) -> Port { panic IOError { code: 1 } }
    fn get(self) panic -> i32 { return read_file(self.n) }
}

fn members() -> i32 {
    var a = Port::make(1)
    var b = a + a
    return b.get()
}

// It propagates: the bare `panic` takes everything left.
fn propagates(x: i32) panic -> i32 {
    var p = Port(x)
    return parse(x) + p.get()
}

fn main() -> i32 {
    return all_arms(1) + bare_catch(2) + nested(3)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: unhandled.k:26:12: error [SC001E]: unhandled panic: 'parse' may panic with 'IOError' and 'ParseError', and 'propagates_nothing' is not marked 'panic'
// CHECK-NEXT: fix-it:"{{.*}}unhandled.k":{25:30-25:30}:" panic"
// CHECK-NEXT: unhandled.k:19:1: note [SC001N]: 'parse' is declared 'panic' here
// CHECK-NEXT: unhandled.k:26:12: note [SC001N]: or handle it here
// CHECK-NEXT: fix-it:"{{.*}}unhandled.k":{26:12-26:12}:"try "
// CHECK-NEXT: fix-it:"{{.*}}unhandled.k":{26:20-26:20}:" catch => crash!()"
// CHECK: unhandled.k:30:16: error [SC001E]: unhandled panic: this 'panic' raises 'IOError', and 'raises' is not marked 'panic'
// CHECK-NEXT: fix-it:"{{.*}}unhandled.k":{29:18-29:18}:" panic"
// CHECK: unhandled.k:37:16: error [SC001E]: unhandled panic: 'parse' may panic with 'ParseError', and 'partial' is not marked 'panic'
// CHECK-NEXT: fix-it:"{{.*}}unhandled.k":{35:19-35:19}:" panic"
// CHECK-NEXT: unhandled.k:19:1: note [SC001N]: 'parse' is declared 'panic' here
// CHECK-NEXT: unhandled.k:37:16: note [SC001N]: or handle it here
// CHECK-NEXT: fix-it:"{{.*}}unhandled.k":{37:16-37:16}:"try "
// CHECK-NEXT: fix-it:"{{.*}}unhandled.k":{37:24-37:24}:" catch => crash!()"
// CHECK: unhandled.k:64:16: error [SC001E]: unhandled panic: 'parse' may panic with 'IOError' and 'ParseError', and 'panics_in_arm' is not marked 'panic'
// CHECK-NEXT: fix-it:"{{.*}}unhandled.k":{60:25-60:25}:" panic"
// CHECK-NEXT: unhandled.k:19:1: note [SC001N]: 'parse' is declared 'panic' here
// CHECK-NEXT: unhandled.k:64:16: note [SC001N]: or handle it here
// CHECK-NEXT: fix-it:"{{.*}}unhandled.k":{64:16-64:16}:"try "
// CHECK-NEXT: fix-it:"{{.*}}unhandled.k":{64:24-64:24}:" catch => crash!()"
// CHECK: unhandled.k:65:7: warning [SC001W]: this arm never runs: 'ParseError' is not in the panic set of its 'try' (this 'try' may panic only with 'IOError')
// CHECK-NEXT: fix-it:"{{.*}}unhandled.k":{65:7-67:6}:""
// CHECK: unhandled.k:94:13: error [SC001E]: unhandled panic: 'make' may panic with 'ParseError', and 'members' is not marked 'panic'
// CHECK-NEXT: fix-it:"{{.*}}unhandled.k":{93:13-93:13}:" panic"
// CHECK-NEXT: unhandled.k:85:5: note [SC001N]: 'make' is declared 'panic' here
// CHECK-NEXT: unhandled.k:94:13: note [SC001N]: or handle it here
// CHECK-NEXT: fix-it:"{{.*}}unhandled.k":{94:13-94:13}:"try "
// CHECK-NEXT: fix-it:"{{.*}}unhandled.k":{94:26-94:26}:" catch => crash!()"
// CHECK: unhandled.k:95:13: error [SC001E]: unhandled panic: this operator may panic with 'IOError', and 'members' is not marked 'panic'
// CHECK-NEXT: fix-it:"{{.*}}unhandled.k":{93:13-93:13}:" panic"
// CHECK-NEXT: unhandled.k:89:5: note [SC001N]: 'op +' is declared 'panic' here
// CHECK-NEXT: unhandled.k:95:13: note [SC001N]: or handle it here
// CHECK-NEXT: fix-it:"{{.*}}unhandled.k":{95:13-95:13}:"try "
// CHECK-NEXT: fix-it:"{{.*}}unhandled.k":{95:18-95:18}:" catch => crash!()"
// CHECK: unhandled.k:96:12: error [SC001E]: unhandled panic: 'get' may panic with 'IOError', and 'members' is not marked 'panic'
// CHECK-NEXT: fix-it:"{{.*}}unhandled.k":{93:13-93:13}:" panic"
// CHECK-NEXT: unhandled.k:90:5: note [SC001N]: 'get' is declared 'panic' here
// CHECK-NEXT: unhandled.k:96:12: note [SC001N]: or handle it here
// CHECK-NEXT: fix-it:"{{.*}}unhandled.k":{96:12-96:12}:"try "
// CHECK-NEXT: fix-it:"{{.*}}unhandled.k":{96:19-96:19}:" catch => crash!()"
