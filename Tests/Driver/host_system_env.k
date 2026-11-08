// The default build honors the env search paths where clang's driver puts
// them: CPATH as -I after the command line's own, C_INCLUDE_PATH and
// CPLUS_INCLUDE_PATH as the per-language system groups (after -isystem,
// before -idirafter), LIBRARY_PATH as -L after the sysroot's dirs and before
// the host's defaults. A --target build ignores all of them, so a cross
// build is the same on every machine.
//
// A static archive taken from a host dir is warned about: what it needs
// from glibc is invisible once it is linked in.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: default-glibc
// RUN: rm -rf %t && mkdir -p %t/cpath %t/cinc %t/cxxinc %t/lib && touch %t/lib/libhoststatic.a
// RUN: env CPATH=%t/cpath C_INCLUDE_PATH=%t/cinc CPLUS_INCLUDE_PATH=%t/cxxinc %kairo %s --print-clang-args | %FileCheck %s --check-prefix=CC1 -DT=%t
// CC1:      clang -cc1
// CC1-SAME: -I {{[^ ]*}}/Lib -I [[T]]/cpath -c-isystem [[T]]/cinc -cxx-isystem [[T]]/cxxinc
// RUN: env CPATH=%t/cpath C_INCLUDE_PATH=%t/cinc CPLUS_INCLUDE_PATH=%t/cxxinc %kairo %s --print-clang-args --target=x86_64-linux-gnu | %FileCheck %s --check-prefix=CC1H -DT=%t
// CC1H:     clang -cc1
// CC1H-NOT: [[T]]

// RUN: env LIBRARY_PATH=%t/lib %kairo %s --print-jobs | %FileCheck %s --check-prefix=LD -DT=%t
// LD:      ld.lld
// LD-SAME: -L{{[^ ]*}}glibc2.31/lib -L[[T]]/lib
// RUN: env LIBRARY_PATH=%t/lib %kairo %s --print-jobs --target=x86_64-linux-gnu | %FileCheck %s --check-prefix=LDH -DT=%t
// LDH:     ld.lld
// LDH-NOT: [[T]]

// RUN: { env LIBRARY_PATH=%t/lib %kairo %s -l hoststatic --print-jobs 2>&1 || true; } | %FileCheck %s --check-prefix=STATIC -DT=%t
// STATIC: warning [L002W]: [[T]]/lib/libhoststatic.a is a static archive from the host system: it was built against the host's glibc, and linking it can silently raise the glibc this program needs above the floor (2.31)
