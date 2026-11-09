// An implicit conversion through `@implicit op as` is a call no node
// shows, on either tree: EmitIR spells it as a cast from the two types.
// A const / @pure function may make it only when the operator keeps the
// promise too: `conv` and `conv_ret` convert through `Bumps`', which
// writes a global, and are rejected at the converted expression;
// `conv_pure` converts through a @pure one and is clean. Inference over
// the same call: Codegen/purity/infer_implicit_conv.k.

var hits: i32 = 0

struct Bumps {
    var x: i32
    @implicit fn op as (const self) -> i32 { hits = hits + 1; return self.x }
}

struct Reads {
    var x: i32
    @implicit @pure fn op as (const self) -> i32 { return self.x }
}

fn eats(x: i32) const -> i32 { return x }

@pure fn conv(b: Bumps) -> i32 { return eats(b) }
@pure fn conv_ret(b: Bumps) -> i32 { return b }
@pure fn conv_pure(r: Reads) -> i32 { return eats(r) }

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK-DAG: purity_implicit_conv.k:23:46: error [SC200E]: 'conv' is @pure, so it cannot call 'op as', which is not a const fn
// CHECK-DAG: purity_implicit_conv.k:24:45: error [SC200E]: 'conv_ret' is @pure, so it cannot call 'op as', which is not a const fn
// CHECK-NOT: error [SC200E]
