// A header written by `--emit-headers` for a module that defines a
// `@relocatable` record refuses a compiler without `trivial_abi`: that
// compiler would pass the record through memory where Kairo's object code
// passes it in registers. C++ that includes the header receives the record
// by value and returns it the way Kairo does, and the two link and run.

static live: i32 = 0

@relocatable
pub class Res {
    pub var id:  usize
    pub var pad: usize

    pub fn Res(self, id: usize) {
        self.id  = id
        self.pad = id
        live += 1
    }

    @move pub fn Res(self, other: Self) {
        self.id  = other.id
        self.pad = other.pad
        other.id = 0
    }

    pub fn op finally(self) {
        if self.id != 0 {
            live -= 1
        }
    }
}

@no_inline pub fn make(id: usize) -> Res {
    return Res(id)
}

@no_inline pub fn take(r: Res) -> usize {
    return r.id + r.pad
}

pub fn live_count() -> i32 {
    return live
}

// --- lit wiring -----------------------------------------------------------
// The guard follows `#pragma once`, once.
// REQUIRES: clang, default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s --type-check-only --emit-headers %t.d/h
// RUN: %FileCheck %s --check-prefix=HDR < %t.d/h/header_abi.hh
// HDR:      #pragma once
// HDR-NEXT: #if !defined(__clang__) || !__has_cpp_attribute(clang::trivial_abi)
// HDR-NEXT: #error "Kairo headers require the Kairo Clang toolchain (trivial_abi)"
// HDR-NEXT: #endif
// HDR-NOT:  #error
// HDR:      class __attribute__((trivial_abi)) Res {
// HDR-NEXT: public{{ *}}: using __kairo_relocatable = Res;
// HDR-NOT:  #error

// A compiler that is not clang is refused, by the guard and nothing else.
// RUN: printf '#include "h/header_abi.hh"\nheader_abi::Res pass(header_abi::Res r) { return r; }\nint main() {\n    header_abi::Res a = pass(header_abi::make(21));\n    unsigned long got = header_abi::take(pass(static_cast<header_abi::Res&&>(a)));\n    return (got == 42 && header_abi::live_count() == 0) ? 0 : 1;\n}\n' > %t.d/use.cc
// RUN: { %clangxx -std=c++23 -fsyntax-only -Wno-builtin-macro-redefined -U__clang__ %t.d/use.cc 2>&1 || true; } | %FileCheck %s --check-prefix=REFUSED
// REFUSED: header_abi.hh:3:2: error: "Kairo headers require the Kairo Clang toolchain (trivial_abi)"

// The C++ and the Kairo object link and run: the value goes Kairo -> C++ ->
// C++ -> Kairo by value and is released once.
// RUN: %kairo %t.d/use.cc %s -o %t.exe --cache-dir %t.d/c
// RUN: %t.exe
