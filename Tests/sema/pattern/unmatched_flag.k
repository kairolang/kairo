// `--unmatched` picks what an exhaustive match does with a value no arm
// declares (MatchLowering's UnmatchedPolicy). Only the flag is checked here:
// both spellings are accepted, anything else is the bad-value error.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --unmatched=trap 2>&1 || true; } | %FileCheck %s --check-prefix=OK --allow-empty
// RUN: { %kairo %s --type-check-only --unmatched=unreachable 2>&1 || true; } | %FileCheck %s --check-prefix=OK --allow-empty
// OK-NOT: {{error|warning}}
// RUN: { %kairo %s --type-check-only --unmatched=bogus 2>&1 || true; } | %FileCheck %s --check-prefix=BAD
// BAD: error [U003E]: invalid value 'bogus' for flag '--unmatched'; accepted: trap, unreachable
