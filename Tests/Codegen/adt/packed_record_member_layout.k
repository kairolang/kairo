// A `@packed` record's size as the compiler predicts it (EnumLayoutQuery::
// size_of) is clang's for the class the emitter writes, also when a member
// is itself a record. clang packs a member of POD class type and not
// one of non-POD type, and every Kairo struct with a number field is
// emitted with `{}` initializers, which makes it non-POD: PS1 is 24/8, not
// the 17/1 the old rule gave by packing every member. A generic ADT over
// such a record pins the predicted size with a static_assert beside it, so
// EP<PS1> failed to compile; a declaration-scope `eval if` read the same
// wrong size. Each case below is checked by that static_assert (the
// program compiles only when every prediction is clang's) and printed from
// the run-time `sizeof` / `alignof`.

ffi "c" import "packed_member_cpt.h"
import std::io

struct S1 { var a: i64; var b: u8 }
@packed struct PI { var a: i64; var b: u8 }
enum E { A { v: i32 }, B }
class C { var a: i32  fn C(self) { self.a = 1 } }

@packed struct PS1 { var a: u8; var s: S1 }              // non-POD member: kept aligned
@packed struct PS2 { var a: u8; var s: CPt }             // C struct, POD: packed
@packed struct PS3 { var a: u8; var s: [S1; 2] }         // array of a non-POD record
@packed struct PS4 { var a: u8; var s: i32? }            // a nullable
@packed struct PS5 { var a: u8; var s: E }               // an ADT
@packed struct PS6 { var a: u8; var s: C }               // a class with a constructor
@packed struct PS7 { var a: u8; var s: PI }              // a packed member class: packed
@packed struct PS8 { var a: u8; @align(2) var s: S1 }    // a member @align
@packed @align(4) struct PS9 { var a: u8; var s: PI }    // record @align over a packed member

enum <T> EP { A { p: T }, B }

eval if (sizeof PS1 == 24) && (alignof PS1 == 8) { fn ps1_ok() -> bool { return true } } else { fn ps1_ok() -> bool { return false } }

fn main() -> i32 {
    var e1: EP<PS1> = EP<PS1>::B
    var e2: EP<PS2> = EP<PS2>::B
    var e3: EP<PS3> = EP<PS3>::B
    var e4: EP<PS4> = EP<PS4>::B
    var e5: EP<PS5> = EP<PS5>::B
    var e6: EP<PS6> = EP<PS6>::B
    var e7: EP<PS7> = EP<PS7>::B
    var e8: EP<PS8> = EP<PS8>::B
    var e9: EP<PS9> = EP<PS9>::B
    io::println(f"{sizeof PS1}/{alignof PS1} {sizeof PS2}/{alignof PS2} {sizeof PS3}/{alignof PS3} {sizeof PS4}/{alignof PS4} {sizeof PS5}/{alignof PS5} {sizeof PS6}/{alignof PS6} {sizeof PS7}/{alignof PS7} {sizeof PS8}/{alignof PS8} {sizeof PS9}/{alignof PS9}")
    io::println(f"{sizeof EP<PS1>} {sizeof EP<PS2>} {sizeof EP<PS3>} {sizeof EP<PS4>} {sizeof EP<PS5>} {sizeof EP<PS6>} {sizeof EP<PS7>} {sizeof EP<PS8>} {sizeof EP<PS9>}")
    if !ps1_ok() {
        return 1
    }

    return 0
}

// --- lit wiring -----------------------------------------------------------
// Every instance's size is predicted, not refused: a refused one has no
// static_assert, and the program would compile without checking anything.
// RUN: { %kairo -I %S/../Inputs %s --print-ir 2>/dev/null || true; } | %FileCheck %s --check-prefix=IR
// IR-DAG: static_assert(sizeof({{ ?}}::{{.*}}::EP< ::{{.*}}::PS1>) == {{[0-9]+}});
// IR-DAG: static_assert(sizeof({{ ?}}::{{.*}}::EP< ::{{.*}}::PS2>) == {{[0-9]+}});
// IR-DAG: static_assert(sizeof({{ ?}}::{{.*}}::EP< ::{{.*}}::PS3>) == {{[0-9]+}});
// IR-DAG: static_assert(sizeof({{ ?}}::{{.*}}::EP< ::{{.*}}::PS4>) == {{[0-9]+}});
// IR-DAG: static_assert(sizeof({{ ?}}::{{.*}}::EP< ::{{.*}}::PS5>) == {{[0-9]+}});
// IR-DAG: static_assert(sizeof({{ ?}}::{{.*}}::EP< ::{{.*}}::PS6>) == {{[0-9]+}});
// IR-DAG: static_assert(sizeof({{ ?}}::{{.*}}::EP< ::{{.*}}::PS7>) == {{[0-9]+}});
// IR-DAG: static_assert(sizeof({{ ?}}::{{.*}}::EP< ::{{.*}}::PS8>) == {{[0-9]+}});
// IR-DAG: static_assert(sizeof({{ ?}}::{{.*}}::EP< ::{{.*}}::PS9>) == {{[0-9]+}});

// The printed sizes are the Itanium/ELF ones (an Apple target packs a
// non-POD member anyway); the static_asserts above hold everywhere.
// REQUIRES: default-sysroot, host-linux
// RUN: rm -rf %t.d
// RUN: %kairo -I %S/../Inputs %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT
// OUT: 24/8 9/1 33/1 12/4 12/4 8/4 10/1 24/8 12/4
// OUT-NEXT: 32 10 34 16 16 12 11 32 16
