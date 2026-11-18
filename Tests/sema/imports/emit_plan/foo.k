// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty
//
// CHECK-NOT: error
import bar;

pub class F {
    var b:   bar::B;        // by value  -> B must be COMPLETE in main.cpp
    var deep: *bar::Deep;   // pointer   -> Deep only needs a forward decl
}

pub class Unused { var x: i32; }

pub fn use_f(f: F) -> i32 { return 0; }
