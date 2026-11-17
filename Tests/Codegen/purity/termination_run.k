// A loop that never exits and a recursion that never ends, in functions that
// otherwise keep the const promise: clang must not delete or fold the call
// (`willreturn`), so the program must not finish at any optimization level.
// Case 0 spins (`i += 2` until `i == n`, n odd), case 1 recurses without end
// (a stack overflow at -O0, an endless loop once clang turns the tail call
// into a jump), case 2 is a function-local static whose initializer calls its
// own function (C++'s recursive-initialization abort). None may print.
import std::io

fn spin(n: i32) -> i32 {
    var i = 0
    while i != n { i += 2 }
    return i
}

fn rec(n: i32) -> i32 {
    return rec(n + 1)
}

fn stat(n: i32) -> i32 {
    static x = stat(n + 1)
    return x
}

fn main(argc: i32) -> i32 {
    var kind = argc - 1
    if kind == 0 { io::println(f"spin={spin(argc + 2)}") }
    if kind == 1 { io::println(f"rec={rec(argc)}") }
    if kind == 2 { io::println(f"stat={stat(argc)}") }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s -finfer-purity --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-NOT: (({{const|pure}})) signed int {{spin|rec|stat}}(

// REQUIRES: clang
// RUN: rm -f %t.exe %t.o2.exe
// RUN: rm -rf %t.d
// RUN: %kairo %s -finfer-purity -o %t.exe --cache-dir %t.d/o0
// RUN: %kairo %s -finfer-purity -O2 -o %t.o2.exe --cache-dir %t.d/o2
// RUN: timeout 3 %t.exe > %t.0.out; test $? -ne 0
// RUN: timeout 3 %t.exe a > %t.1.out; test $? -ne 0
// RUN: timeout 3 %t.exe a b > %t.2.out; test $? -ne 0
// RUN: timeout 3 %t.o2.exe > %t.3.out; test $? -ne 0
// RUN: timeout 3 %t.o2.exe a > %t.4.out; test $? -ne 0
// RUN: timeout 3 %t.o2.exe a b > %t.5.out; test $? -ne 0
// RUN: cat %t.0.out %t.1.out %t.2.out %t.3.out %t.4.out %t.5.out | %FileCheck %s --check-prefix=OUT --allow-empty
// OUT-NOT: {{spin|rec|stat}}=
