// Compiler/Native's headers in the Stage 1 world (SELFHOST.md 2.3, P346):
// imported with no lib-helix on any path, they must parse (no CL001E
// "include/core.hh not found") and every Kairo-facing piece must type-check
// from Kairo with Kairo's own types in it -- the shapes the self-hosted
// compiler's sources use:
//
//   StackBuf / Expected over Kairo records (TypeExport stand-ins fill them);
//   sref and Logger over a Kairo string, an f-string and a literal (the
//   native::bytes template takes any of them);
//   ice_fail, the [[noreturn]] Stage 1 entry point, behind the Kairo macro
//   the migration spells ICE_IF / ICE_FAIL as: a non-void function whose
//   last statement is ice_fail! needs no return after it;
//   the plain C++ std aliases (Mutex, MemoryOrder).
//
// Names are spelled kairo::..., not bare: Stage 1 does not wrap a Kairo file
// in namespace kairo the way Stage 0 does, so a C++ `kairo::std::X` is
// reached by its full name (the self-host migration's rewrite).

ffi "c++" import "Native/Types.hh"
ffi "c++" import "Native/SmallFunction.hh"

import std::c_char

macro ice_if!(cond, msg) { if cond { kairo::std::ice_fail(msg) } }
macro ice_fail!(msg)     { kairo::std::ice_fail(msg) }

struct Node { var v: i32 }
enum ResolveError { NotFound, Ambiguous }

fn stack_sum() -> i32 {
    var buf: kairo::std::StackBuf<Node, 2>
    buf.push_back(Node{v: 1})
    buf.push_back(Node{v: 2})
    buf.push_back(Node{v: 3})               // past the inline capacity: grows to the heap
    var sum: i32 = 0
    for var i: u32 = 0; i < buf.size(); ++i { sum += buf[i].v }
    return sum
}

fn expect_found(ok: bool) -> kairo::std::Expected<Node, ResolveError> {
    if ok { return kairo::std::Expected<Node, ResolveError>(Node{v: 9}) }
    return kairo::std::Expected<Node, ResolveError>(ResolveError::NotFound)
}

fn expected_value() -> i32 {
    var r = expect_found(true)
    if !r.check() { return -1 }
    return r.value_or(Node{v: 0}).v
}

fn text(n: i32) -> usize {
    var s: string = "abc"
    var a = kairo::sref(s)
    var b = kairo::sref(f"n={n}")
    var c = kairo::sref("lit")
    return a.size() + b.size() + c.size()
}

fn log(n: i32) {
    kairo::Logger::info(kairo::Logger::Stage::Driver, f"n={n}")
    kairo::Logger::warn(kairo::Logger::Stage::Sema, "plain")
}

fn checked(n: i32) -> i32 {
    ice_if!(n < 0, f"negative: {n}")
    if n > 100 { return n }
    ice_fail!("unreachable")
}

fn locks() {
    var m: kairo::std::Mutex
    m.lock()
    m.unlock()
    var order = kairo::std::MemoryOrder::relaxed
}

fn triple() -> unsafe *const c_char {
    return kairo::std::default_target_triple_cstr()
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only -I %S/../../../Compiler --ffi-include %S/../../../Lib/llvm-runtimes/llvm/include --ffi-include %S/../../../build/llvm/include 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error
// DIAG-NOT: warning
