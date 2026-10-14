// An explicit value on a Bool flag must be one of true/false/1/0/yes/no/on/off
// (any case). Anything else used to be read as true, so `--strip=bogus` was
// accepted. Feature flags take no value at all: `-fX=bogus` is U003E.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --type-check-only --strip=true --strip=FALSE --strip=1 --strip=0 --strip=Yes --strip=no --strip=ON --strip=off
// RUN: { %kairo %s --type-check-only --strip=bogus 2>&1 || true; } | %FileCheck %s --check-prefix=BAD
// BAD: error [U003E]: invalid value 'bogus' for flag '--strip'; accepted: true, false, 1, 0, yes, no, on, off
// RUN: { %kairo %s --type-check-only -fvectorize=bogus 2>&1 || true; } | %FileCheck %s --check-prefix=FEAT
// FEAT: error [U003E]: invalid value 'bogus' for flag '-fvectorize'
