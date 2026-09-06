// RUN: %kairo %s --type-check-only 2>&1 | %FileCheck %s --allow-empty
//
// Support file for main.k: the module every import form in that file names.
// Its own two import edges are the re-export test -- one public, one private.
//
// CHECK-NOT: error

pub import bar::*
import baz

pub fn add(a: i32, b: i32) -> i32 { return a + b }

pub class MyClass {
    pub { var v: i32 }
}

pub module inner {
    pub fn g() -> i32 { return 3 }
}
