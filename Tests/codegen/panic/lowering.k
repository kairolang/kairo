// PanicLowering end to end (PANIC.md §4): PANIC.md §4.5a's worked examples
// A-K, compiled, linked and run at -O0 and -O2. Each check returns its own
// code; 0 is every one right.
//   A  propagate, raise, tail-propagate        (load_port)
//   B  statement try, two sites, exhaustive    (config_port)
//   C  partial, `return` in the body           (partial)
//   D  expression try, exhaustive              (dexpr)
//   E  expression try, partial                 (eexpr)
//   F  nested try, the leftover to the outer   (nested)
//   G  a call under `&&` runs on its branch    (guarded)
//   I  re-panic from an arm keeps the site     (repanic)
//   K  a `void` panicking function             (void_fn)
// and a bare `catch e` re-panic, a bare arm's value, an arm that returns.

struct ParseError { var code: i32 }
struct IOError { var code: i32 }

fn read_file(n: i32) panic(IOError) -> i32 {
    if n == 7 { panic IOError { code: 7 } }
    return n
}
fn parse_port(n: i32) panic(ParseError) -> i32 {
    if n < 0 { panic ParseError { code: n } }
    return n + 1
}
fn parse_and_validate(n: i32) panic(ParseError, IOError) -> i32 {
    return parse_port(read_file(n))
}
fn load_port(n: i32) panic -> i32 {
    var text = read_file(n)
    if text == 0 { panic ParseError { code: 99 } }
    return parse_port(text)
}
fn config_port(n: i32) -> i32 {
    var port: i32
    try { port = parse_port(read_file(n)) } catch e: ParseError { port = 8080 } catch e: IOError { port = 80 + e.code }
    return port
}
fn partial(n: i32) panic -> i32 {
    try { return parse_and_validate(n) } catch e: ParseError { return -1 }
}
fn dexpr(n: i32) -> i32 { var port = try parse_port(n) catch e: ParseError => 8080; return port }
fn eexpr(n: i32) panic -> i32 { var v = try parse_and_validate(n) catch e: ParseError => -1;  return v }
fn nested(n: i32) -> i32 {
    var r: i32 = 0
    try {
        try { r = parse_and_validate(n) } catch e: ParseError { r = 1 }
    } catch e: IOError { r = e.code }
    return r
}
fn guarded(c: bool, n: i32) panic -> i32 {
    if c && (parse_port(n) > 2) { return 1 }
    return 0
}
fn repanic(n: i32) panic -> i32 {
    try { return parse_and_validate(n) } catch e: ParseError { return -1 } catch e: IOError { panic e }
}
var trace: i32 = 0
fn void_fn(n: i32) panic(IOError) {
    if n == 7 { panic IOError { code: 3 } }
    trace = trace + 1
}
fn bare(n: i32) panic -> i32 {
    try { return parse_and_validate(n) } catch e { panic e }
}
fn bare_value(n: i32) -> i32 {
    return try parse_and_validate(n) catch e: IOError => 5 catch => 6
}
fn jump_arm(n: i32) -> i32 {
    var v = try parse_port(n) catch => return 77
    return v
}

fn main() -> i32 {
    if (try load_port(3) catch => 0) != 4 { return 1 }
    if (try load_port(0) catch e: ParseError => e.code catch => 0) != 99 { return 2 }
    if (try load_port(7) catch e: IOError => e.code catch => 0) != 7 { return 3 }
    if config_port(3) != 4 { return 4 }
    if config_port(7) != 87 { return 5 }
    if config_port(-5) != 8080 { return 6 }
    if (try partial(-2) catch => 0) != -1 { return 7 }
    if (try partial(7) catch e: IOError => 100 + e.code) != 107 { return 8 }
    if (try partial(1) catch => 0) != 2 { return 9 }
    if dexpr(-1) != 8080 { return 10 }
    if dexpr(4) != 5 { return 11 }
    if (try eexpr(-3) catch => 0) != -1 { return 12 }
    if (try eexpr(7) catch => 55) != 55 { return 13 }
    if nested(-1) != 1 { return 14 }
    if nested(7) != 7 { return 15 }
    if nested(2) != 3 { return 16 }
    if (try guarded(false, -1) catch => 9) != 0 { return 17 }
    if (try guarded(true, -1) catch => 9) != 9 { return 18 }
    if (try guarded(true, 5) catch => 9) != 1 { return 19 }
    if (try repanic(7) catch e: IOError => e.code) != 7 { return 20 }
    try { void_fn(1) } catch { return 21 }
    try { void_fn(7) } catch e: IOError { trace = trace + e.code }
    if trace != 4 { return 22 }
    if (try bare(7) catch e: IOError => e.code catch => 0) != 7 { return 23 }
    if bare_value(7) != 5 { return 24 }
    if bare_value(-4) != 6 { return 25 }
    if jump_arm(-4) != 77 { return 26 }
    if jump_arm(4) != 5 { return 27 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d %t.o2
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.o2
// RUN: %t.o2.exe

// The shapes (§4.1-§4.4): a panicking signature returns the formed result;
// a tail `return g()` forwards it whole; a held call is tested where it sat;
// two sites share a raw slot, moved out into a local at the dispatch, and
// `catch e: E` is one compare of the tag with E's id, `e` a reference to
// the payload; a single-site `try` reads its call's own result (no slot).
// RUN: { %kairo %s --print-ir 2>/dev/null || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: Panic<signed int,{{.*}}> parse_and_validate(signed int n) noexcept {
// CXX: return{{ ?}}::__kairo_fwd<{{.*}}, true>(
// CXX-LABEL: signed int config_port(signed int n) noexcept {
// CXX: ::__kairo_raw<{{.*}}Panic<void,{{.*}}>> __kairo_s[[S:[0-9]+]];
// CXX: = {{.*}}read_file(n);
// CXX-NEXT: if((!(static_cast<unsigned int>(__kairo_p{{[0-9]+}}.__kairo_tag) == 0))) {
// CXX-NEXT: new(& __kairo_s[[S]].__kairo_b)::__kairo_rbox<
// CXX: goto __kairo_catch[[C:[0-9]+]];
// CXX: __kairo_catch[[C]]:;
// CXX: __kairo_e[[E:[0-9]+]] = __kairo_s[[S]].__kairo_take();
// CXX-NEXT: if(static_cast<unsigned int>(__kairo_e[[E]].__kairo_tag) == {{[0-9]+}}) {
// CXX-NEXT: ParseError & e = __kairo_e[[E]].__kairo_Err.template __kairo_get<{{[01]}}>().error;
// CXX-LABEL: partial(signed int n) noexcept {
// CXX-NOT: __kairo_raw
// CXX: __kairo_p{{[0-9]+}} = {{.*}}parse_and_validate(n);
// CXX-LABEL: IOError> void_fn(signed int n) noexcept {
