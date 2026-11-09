// Compiler/Native's runtime pieces, compiled by Stage 1 and run, the
// behaviour the compiler relies on, with Kairo types in the C++ templates.
//
//   StackBuf  keeps N inline and grows to the heap past them; the elements
//             survive the move (sum 1+2+3).
//   Expected  holds a value or an error, never both; check() says which.
//   sref      sees the exact bytes, embedded NUL included.
//   ice_fail  prints the ICE banner with the message on stderr and abort()s
//             (not exit): the process dies on SIGABRT, and nothing after it
//             runs. Under the Kairo macro the migration uses for ICE_IF, a
//             passing check builds no message.
//
// The LLVM headers Types.hh pulls in are compiled, never linked: nothing here
// instantiates Logger::log, the one LLVM call; ABI-breaking-check enforcement
// is off so the header's weak reference to LLVMSupport goes unresolved.

ffi "c++" import "Native/Types.hh"

import std::io

macro ice_if!(cond, msg) { if cond { kairo::std::ice_fail(msg) } }

struct Node { var v: i32 }
enum ResolveError { NotFound, Ambiguous }

fn find(ok: bool) -> kairo::std::Expected<Node, ResolveError> {
    if ok { return kairo::std::Expected<Node, ResolveError>(Node{v: 9}) }
    return kairo::std::Expected<Node, ResolveError>(ResolveError::Ambiguous)
}

var built: i32 = 0

fn label(n: i32) -> string {
    built += 1
    return f"bad {n}"
}

fn main() -> i32 {
    var buf: kairo::std::StackBuf<Node, 2>
    buf.push_back(Node{v: 1})
    buf.push_back(Node{v: 2})
    buf.push_back(Node{v: 3})
    var sum: i32 = 0
    for var i: u32 = 0; i < buf.size(); ++i { sum += buf[i].v }
    io::println(f"stackbuf {sum} {buf.size()}")

    var a = find(true)
    var b = find(false)
    io::println(f"expected {a.check()} {a.value_or(Node{v: 0}).v} {b.check()}")

    var s: string = "ab"
    s.push_back(0)
    s.push_back(99)
    var n: usize = kairo::sref(s).size()
    io::println(f"sref {n}")

    ice_if!(sum != 6, label(sum))
    io::println(f"messages built {built}")

    ice_if!(sum == 6, label(sum))
    io::println("not reached")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d -I %S/../../Compiler --ffi-include %S/../../Lib/llvm-runtimes/llvm/include --ffi-include %S/../../build/llvm/include --cxx-define LLVM_DISABLE_ABI_BREAKING_CHECKS_ENFORCING=1 2>&1 | %FileCheck %s --check-prefix=BUILD --allow-empty
// BUILD-NOT: {{error|warning}}
// RUN: not --crash %t.exe > %t.out 2> %t.err
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// RUN: %FileCheck %s --check-prefix=ERR < %t.err
//
// OUT:      stackbuf 6 3
// OUT-NEXT: expected true 9 false
// OUT-NEXT: sref 4
// OUT-NEXT: messages built 0
// OUT-NOT:  not reached
//
// ERR:      Kairo Internal Compiler Error: bad 6
// ERR-NEXT: This is a bug in the Kairo compiler.
// ERR-NEXT: Location: {{.+}}:{{[0-9]+}}:{{[0-9]+}}
// ERR-NEXT: Please report it: https://github.com/kairolang/kairo/issues
