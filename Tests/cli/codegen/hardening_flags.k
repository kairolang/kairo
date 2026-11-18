// The codegen flags kairo spells itself, on Kairo's own cc1 line. There is
// no clang passthrough: a word after a bare `--` is an input, and one that
// looks like a flag is told where its kairo spelling or --cxx-flags is.

thread counter: i32 = 0

fn main() -> i32 { counter = 1; return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --stack-protector=strong --cf-protection=full --tls-model=initial-exec --visibility=hidden -fno-plt -fno-red-zone --mcmodel=medium --trivial-auto-var-init=pattern --zero-call-used-regs=used-gpr -fno-delete-null-pointer-checks -fvisibility-inlines-hidden || true; } | %FileCheck %s --check-prefix=CC1
// CC1: -stack-protector 2
// CC1-SAME: -fcf-protection=full
// CC1-SAME: -fzero-call-used-regs=used-gpr
// CC1-SAME: -ftrivial-auto-var-init=pattern
// CC1-SAME: -fno-delete-null-pointer-checks
// CC1-SAME: -ftls-model=initial-exec
// CC1-SAME: -fvisibility=hidden
// CC1-SAME: -fvisibility-inlines-hidden
// CC1-SAME: -fno-plt
// CC1-SAME: -disable-red-zone
// CC1-SAME: -mcmodel=medium

// The explicit level wins over the -f shorthand; -fno-stack-protector is none.
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl -fstack-protector --stack-protector=all || true; } | %FileCheck %s --check-prefix=ALL
// ALL: -stack-protector 3
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl -fno-stack-protector || true; } | %FileCheck %s --check-prefix=NONE
// NONE-NOT: -stack-protector

// A value outside the list is rejected.
// RUN: { %kairo %s --print-clang-args --tls-model=fast 2>&1 || true; } | %FileCheck %s --check-prefix=BAD
// BAD: tls-model

// --tls-model sets a user `thread` global's attribute too (an executable's
// would otherwise be local-exec).
// RUN: { %kairo %s --print-ir --target=x86_64-linux-musl --tls-model=global-dynamic || true; } | %FileCheck %s --check-prefix=ATTR
// ATTR: tls_model("global-dynamic")

// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: { %kairo %s -o %t.d/a.out -- -ftls-model=initial-exec 2>&1 || true; } | %FileCheck %s --check-prefix=DASH
// DASH: '-ftls-model=initial-exec' after -- is an input, not a flag

// cc1 takes them all: a real build links and runs.
// RUN: %kairo %s -o %t.d/hard --cache-dir %t.d/c --stack-protector=strong --cf-protection=full --tls-model=initial-exec -fno-plt -fno-red-zone --trivial-auto-var-init=zero --zero-call-used-regs=used-gpr -fno-delete-null-pointer-checks
// RUN: %t.d/hard
