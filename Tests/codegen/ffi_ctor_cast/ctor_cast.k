// `x as T` through a constructor (casting.md, Conversion Through a
// Constructor) where T is an instance of an imported class template:
// `Tag() as WT<i32>`. OperatorLowering mints the constructor call, and
// CallLowering / EmitIR recognised a constructor by its name matching its
// owner's; an instance's owner is the instance, so `self` is not counted as
// an argument (no "short of arguments" ICE). The minted call
// carries ctor_decl, as a constructor call X typed does.

ffi "c++" import "ctor_cast.h"

fn main() -> i32 {
    var a = Tag() as WT<i32>
    var b = Tag() as W
    return a.v + b.v      // 5 + 6
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error [

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 11
