// A class template bounded by an interface calls through the bound's
// witness (`Both_witness<S>::get`) in its member bodies, but a primary
// record's head carries no requires clause, and the bound's primaries were
// admitted only from one: nothing else here names Both, so the header named
// a witness it never declared and did not compile (as builtin/base/alloc.hh
// did for AllocatorScope<A impl ScopedFullAllocator>).
pub interface Source {
    static fn get() -> i32
}

pub interface Both derives Source { }

pub class <S impl Both> Reader {
    priv var v: i32

    pub inline fn Reader(self) {
        self.v = S::get()
    }

    pub inline fn value(const self) -> i32 { return self.v }
}

// --- lit wiring ---
// REQUIRES: clang
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s --type-check-only --emit-headers %t.d/h
// RUN: %FileCheck %s --check-prefix=HDR < %t.d/h/emit_headers_witness_bound.hh
// RUN: printf '#include "emit_headers_witness_bound.hh"\nint f() { return 0; }\n' > %t.d/use.cc
// RUN: { %clangxx -std=c++23 -fsyntax-only -I %t.d/h -I %S/../../Lib %t.d/use.cc 2>&1 || true; } | %FileCheck %s --check-prefix=CXX --allow-empty

// HDR: template<class __kairo_Self> struct Both_witness;
// HDR: Both_witness<S>::get()

// CXX-NOT: error
