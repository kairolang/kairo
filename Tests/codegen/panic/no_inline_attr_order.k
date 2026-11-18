// A standard attribute leads a function's decl-specifiers. The
// interface declared a panicking `@no_inline` function as
// `__attribute__((noinline)) [[nodiscard]] ...`, and clang reads a `[[...]]`
// that follows a GNU attribute as appertaining to the type: "'nodiscard'
// attribute cannot be applied to types". `[[noreturn]]` after `virtual` on a
// method was the same mistake. Both come first.

struct A { var v: i32 }

@no_inline
fn ab(n: i32) panic(A) -> i32 {
    if n < 0 { panic A { v: n } }
    return n
}

@cold_path
fn cold(n: i32) panic(A) -> i32 {
    if n < 0 { panic A { v: n } }
    return n + 1
}

class Box {
    pub var k: i32 = 2

    @no_inline
    pub fn get(self, n: i32) panic(A) -> i32 {
        if n < 0 { panic A { v: n } }
        return self.k + n
    }

    @no_inline
    virtual fn stop(self) -> ! { while true { } }
}

fn main() -> i32 {
    var b = Box()
    try {
        return ab(3) + cold(4) + b.get(1)               // 3 + 5 + 3 == 11
    } catch e: A {
        return 1
    }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR-DAG: {{\[\[}}nodiscard{{\]\]}} __attribute{{.*}}noinline{{.*}} ab(signed int n)
// IR-DAG: {{\[\[}}nodiscard{{\]\]}} __attribute{{.*}}noinline{{.*}} get(signed int n)
// IR-DAG: {{\[\[}}noreturn{{\]\]}} virtual __attribute{{.*}}noinline{{.*}} stop()

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 11
