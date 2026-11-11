// -DNAME=VALUE defines NAME as VALUE, exactly like --define=NAME=VALUE. The
// single-dash path must not split `-DFOO=7` into `-D` + "FOO" and then let the
// `=7` overwrite the name, which pushes the define "7" and no FOO.
// A bare -DNAME defines NAME as 1. Pinned through --dump-preprocessed, where
// the expanded value is visible as text.

fn main() -> i32 { return BAR! }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --dump-preprocessed -DBAR=7 | %FileCheck %s --check-prefix=VAL
// RUN: %kairo %s --dump-preprocessed -D BAR=7 | %FileCheck %s --check-prefix=VAL
// RUN: %kairo %s --dump-preprocessed --define=BAR=7 | %FileCheck %s --check-prefix=VAL
// VAL: return 7
// RUN: %kairo %s --dump-preprocessed -DBAR | %FileCheck %s --check-prefix=ONE
// RUN: %kairo %s --dump-preprocessed -D BAR | %FileCheck %s --check-prefix=ONE
// ONE: return 1
