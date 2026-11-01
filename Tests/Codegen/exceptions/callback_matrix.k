// Kairo functions as C++ callbacks, and C++ exceptions and Kairo panics
// crossing the boundary, in one program whose output is checked line by line
// (the other tests here each isolate one of these and assert by exit code):
//  1. a Kairo fn passed where C++ takes `int (*)(int)`;
//  2-3. an `@unwind` callback: no throw, then `checked` throws through it
//       and the C++ `guard` above catches (-1);
//  4. a Kairo `try` catching a C++ exception, expression form;
//  5. a Kairo panic caught as a value through its binding;
//  6. a noexcept (default) callback the exception reaches: std::terminate,
//     after everything above was printed.
// A panicking fn passed as the C pointer is a compile error, see
// panicking_fn_to_c_pointer.k. Output goes through the C++ `say`, which
// flushes, so lines 1-5 survive the abort and the test needs nothing of std.
ffi "c++" import "guard.hh"

struct Negative {
    var v: i32
}

extend Negative {
    fn op panic (const self) -> string { return f"negative: {self.v}" }
}

fn plain(x: i32) -> i32 { return x + 1 }

@unwind fn relay(x: i32) -> i32 { return checked(x) + 1 }

fn sealed(x: i32) -> i32 { return checked(x) + 1 }

fn may_fail(x: i32) panic(Negative) -> i32 {
    if x < 0 { panic Negative { v: x } }
    return x
}

fn main() -> i32 {
    say(1, apply(plain, 4))
    say(2, guard(relay, 3))
    say(3, guard(relay, -3))

    var r = try checked(-1) catch e: cxx::std::exception => -2
    say(4, r)

    var p = try may_fail(-5) catch e: Negative => e.v
    say(5, p)

    say(6, guard(sealed, -3))
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR: signed int relay(signed int x) {
// IR: signed int sealed(signed int x) noexcept {

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out 2> %t.err; test $? -eq 134
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// RUN: %FileCheck %s --check-prefix=ERR < %t.err
// OUT:      1 5
// OUT-NEXT: 2 7
// OUT-NEXT: 3 -1
// OUT-NEXT: 4 -2
// OUT-NEXT: 5 -5
// OUT-NOT:  6
// ERR: terminat{{.*}}runtime_error
