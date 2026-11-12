// Through kcc: `#include "x.k"` of a module whose class template is
// bounded by an interface nothing else names. The member bodies call the
// bound's witness (`Both_witness<S>::get`), which the injected interface
// never declared, so kcc failed (CL001E, no member named 'Both_witness').
// The C++ host instantiates the template with its own conforming type.
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
// REQUIRES: kcc, default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d && cd %t.d
// RUN: printf '#include "%s"\nstruct Src { static int get() { return 7; } };\nint main() { kcc_witness_bound::Reader<Src> r; return r.value(); }\n' > %t.d/host.cc
// RUN: %kcc %t.d/host.cc -o %t.d/main
// RUN: %t.d/main; test $? -eq 7
