// A `catch` arm of a C++ exception type starts from every state the `try`
// body can be in when a C++ call throws, which the walk does not see: the
// state after the body is one of them. Here the move of `a` follows a
// Kairo panic point, and the C++ call after the move can throw into the
// `cxx::std::exception` arm, where `a` is moved-from (SC052E).
ffi "c++" import "../../Codegen/lifecycle/finally_unwind.hh"

struct Bad { var n: i32 }

class Mv {
    var id: i32 = 0
    fn Mv(self, id: i32) { self.id = id }
    @move fn Mv(self, other: Self) { self.id = other.id }
}

fn may(x: i32) panic(Bad) -> i32 {
    if x < 0 { panic Bad { n: x } }
    return x
}

fn f(x: i32) -> i32 {
    var a = Mv(1)
    var r = 0
    try {
        var v = may(x)
        var b = a
        r = checked(v)
    } catch e: Bad {
        r = 0
    } catch e: cxx::std::exception {
        r = a.id
    }

    return r
}

fn main() -> i32 { return f(1) }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: movecheck_cxx_arm_entry.k:31:13: error [SC052E]: 'a' is used after being moved
