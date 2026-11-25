// A run-time assertion message in its other forms: a parameter, a
// concatenation and an f-string, each evaluated when its assertion fails
// and printed after the condition as written. An empty message prints the
// location and the condition alone. A message past the runtime's 4096-byte
// limit is cut there, not overrun. Each case is its own process, chosen by
// the argument count.

import std::io::println

fn by_param(const note: string) {
    assert 1 > 2, note
}

fn by_concat(const a: string) {
    assert 2 > 3, a.copy() + " and more"
}

fn by_fstring(v: i32) {
    assert v == 0, f"v was {v}"
}

fn empty(const e: string) {
    assert 3 > 4, e
}

fn huge(n: usize) {
    var s = ""
    for var i: usize = 0; i < n; ++i {
        s.push('x')
    }

    assert n == 0, s
}

fn main(argc: i32) -> i32 {
    if argc == 1 { by_param("from a parameter") }
    if argc == 2 { by_concat("joined") }
    if argc == 3 { by_fstring(7) }
    if argc == 4 { empty("") }
    if argc == 5 { huge(10000) }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: rm -f %t.exe
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe 2> %t.e1; test $? -eq 134
// RUN: %FileCheck %s --check-prefix=PARAM --match-full-lines < %t.e1
// RUN: %t.exe a 2> %t.e2; test $? -eq 134
// RUN: %FileCheck %s --check-prefix=CONCAT --match-full-lines < %t.e2
// RUN: %t.exe a b 2> %t.e3; test $? -eq 134
// RUN: %FileCheck %s --check-prefix=FSTR --match-full-lines < %t.e3
// RUN: %t.exe a b c 2> %t.e4; test $? -eq 134
// RUN: %FileCheck %s --check-prefix=EMPTY --match-full-lines < %t.e4
// RUN: %t.exe a b c d 2> %t.e5; test $? -eq 134
// RUN: python3 -c "import sys; d=open(sys.argv[1],'rb').read(); print(len(d), d.count(b'x'), d.endswith(b'x\n'))" %t.e5 | %FileCheck %s --check-prefix=HUGE
// PARAM: kairo: assertion failed at {{.*}}assert_message_forms_run.k:11:5: assert 1 > 2: from a parameter
// CONCAT: kairo: assertion failed at {{.*}}assert_message_forms_run.k:15:5: assert 2 > 3: joined and more
// FSTR: kairo: assertion failed at {{.*}}assert_message_forms_run.k:19:5: assert v == 0: v was 7
// EMPTY: kairo: assertion failed at {{.*}}assert_message_forms_run.k:23:5: assert 3 > 4
// The runtime writes at most 4096 bytes and then a newline.
// HUGE: 4097 {{[0-9]+}} True
