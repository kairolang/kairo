// SI1 follow-up: binding a non-copyable imported record to a reference
// is not a copy. Only a by-value transfer of an lvalue is.
// RUN: { %kairo --type-check-only %s 2>&1 || true; } | %FileCheck %s --allow-empty
// CHECK-NOT: error

ffi "c++" import "Inputs/si1_noncopy.h"
ffi "c++" import "utility"
ffi "c++" import "memory"

fn use_const(const s: Stream) -> i32 { return s.w }
fn use_inout(@inout s: Stream) -> i32 { return s.w }
fn use_move(@move h: NCH) -> i32 { return h.n }

fn <T, ...U> make(...args: U) -> T { return T(...args) }

fn main() -> i32 {
    var k = Sink(&getstream())              // C++ ctor taking Stream&
    var a = use_const(getstream())         // Kairo const param: const T&
    var b = use_inout(&getstream())         // Kairo @inout param: T&
    var h = Holder()
    h.push_back(cxx::std::move(getnch()))  // T&& overload: a move, not a copy
    var k2 = make<Sink>(getstream())       // a pack forwards its arguments
    var m = mk<Sink>(getstream2())            // C++ forwarding-reference pack
    var u = cxx::std::make_unique<Sink>(getstream2())   // std::make_unique forwards
    var u3 = cxx::std::make_unique<Sink3>(getstream(), 2, getstream2())
    return k.w + a + b
}
