// A dead branch of an `eval if` whose condition asks `defined!` is dead
// text: no macro in it is expanded and no `compile_error!` fires. The
// preprocessor decides such a condition when the rest of it is `true`,
// `false`, `!`, `&&`, `||` and parentheses and each name is a Kairo macro
// or a `-D` name. Once a condition of an else-if chain is known true, the
// rest of the chain goes, conditions included. A macro a dead branch
// defines is still defined: a branch is no scope for a macro.
//
// A name that is no Kairo macro may be one of clang's, so its branch is
// decided by Sema: a macro nobody defined is an error there only if the
// branch is kept (the SIZE! below, without -D SIZE).

import std::io::println

macro ON!() { 1 }

// File scope, decided: `ON` is a Kairo macro.
eval if defined!(ON) {
    eval A: i32 = 1
} else if dead_condition!() {
    eval A: i32 = dead_a!() + compile_error!("a dead branch was expanded")
} else {
    eval A: i32 = dead_b!()
}

eval if !defined!(ON) || false {
    eval B: i32 = dead_c!(1, 2)
    macro FROM_DEAD!() { 7 }
} else {
    eval B: i32 = 2 + FROM_DEAD!() - 7
}

// File scope, left to Sema: SIZE is a -D name or nothing.
eval if defined!(SIZE) {
    priv eval N: usize = SIZE!
} else {
    priv eval N: usize = 64
}

class Box {
    // Class body, decided.
    eval if defined!(ON) && !defined!(ON) {
        fn decided(self) -> i32 { return dead_d! }
    } else {
        fn decided(self) -> i32 { return 3 }
    }

    // Class body, left to Sema: the name is no macro of anyone's.
    eval if defined!(__KAIRO_TEST_NO_SUCH_MACRO__) {
        fn open(self) -> i32 { return __KAIRO_TEST_NO_SUCH_MACRO__! }
    }
    else
    {
        fn open(self) -> i32 { return 4 }
    }
}

fn body() -> i32 {
    // Function body, decided, nested in a branch that is kept.
    eval if defined!(ON) {
        eval if (!defined!(ON)) { return dead_e!() }
        return 5
    } else {
        return dead_f!()
    }
}

fn open_body() -> i32 {
    // Function body, left to Sema.
    eval if defined!(__KAIRO_TEST_NO_SUCH_MACRO__) && defined!(ON) {
        return dead_g!(1)
    }

    return 6
}

fn main() -> i32 {
    var b = Box()
    println(f"{A} {B} {N} {b.decided()} {b.open()} {body()} {open_body()}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only -D SIZE=128 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// The dead text is not in the preprocessor's output; an undecided branch is.
// RUN: %kairo %s --dump-preprocessed | %FileCheck %s --check-prefix=PP
// PP-NOT: dead_
// PP: eval if true {
// PP-NEXT: eval A : i32 = 1
// PP-NEXT: }
// PP-NEXT: eval if ! true || false { } else {
// PP-NEXT: eval B : i32 = 2 + 7 - 7
// PP: eval if defined ! ( SIZE ) {
// PP: fn open ( self ) -> i32 { return 4 }

// REQUIRES: clang
// RUN: rm -rf %t.d %t.e
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT
// OUT: 1 2 64 3 4 5 6
// RUN: %kairo %s -D SIZE=128 -o %t2.exe --cache-dir %t.e
// RUN: %t2.exe | %FileCheck %s --check-prefix=SIZED
// SIZED: 1 2 128 3 4 5 6
