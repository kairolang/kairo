// RUN: { %kairo %s --type-check-only --cmax-scope-depth=12 2>&1 || true; } | %FileCheck %s --check-prefix=CAP
// RUN: %kairo %s --type-check-only --cmax-scope-depth=256
//
// A local `var` walked while the resolution stack is full owns no frame.
//
// The chain v0..v11 fills a cap of 12, so the closure body's `var x` is
// walked with nothing pushed for it (begin_decl refuses at the cap). The
// walk must not finish it anyway, popping v11's frame: the stack would read
// one shallower than it is, and the demand for `w` that follows would slip
// under the cap. `x` still types (the walk needs no frame for it); `w` is
// the demand that really met the cap, and is reported as such.

var v0 = v1
var v1 = v2
var v2 = v3
var v3 = v4
var v4 = v5
var v5 = v6
var v6 = v7
var v7 = v8
var v8 = v9
var v9 = v10
var v10 = v11
var v11 = fn () -> i32 {
    var x = 1
    return x + w
}

var w = 5
// CAP: infer_depth_cap_local.k:[[@LINE-1]]:1: error [SC001E]: inferring the type of 'w' exceeded the nested scope limit (12)

fn main() -> i32 { return 0 }

// CAP-NOT: error
