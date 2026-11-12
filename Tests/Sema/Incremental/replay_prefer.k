// Incremental Sema, phase 5: the second tier re-checked towards a preferred
// file (Tooling::LiveCheck::drain's `prefer`: a tool's open buffers; `prefer
// <file>` in a replay script) instead of in the order Sema runs files.
//
// An instance's once-only reports belong to its FIRST use in Sema's order.
// Inputs/live: a.k and b.k do not import each other and name the same
// instances of g.k's generics over s.k's record; a.k comes first. Editing
// s.k queues a.k, b.k and main.k; preferring b.k would make it the first
// user. FrontendAction::prefer_first_users reads, from what the retraction
// recorded and from b.k's dependency log, that a.k was the first user of an
// instance b.k names, and a.k goes before it: every step is a refresh and
// equals a fresh run (stderr and --dump-interface, byte for byte).
// RUN: rm -rf %t.d && mkdir -p %t.d/p && cp -r %S/Inputs/live %t.d/p/s
// RUN: python3 %S/../../../Scripts/incr_replay_check.py --kairo %kairo_bin --root %t.d/p --entry s/main.k --flag=-I --flag=s --flag=--threads=2 --flag=--incr-replay-in-place --two-tier --overlay --script %S/Inputs/live_prefer.replay --scratch %t.d/scratch | %FileCheck %s --implicit-check-not=DIFFERS --implicit-check-not="full (the edited"
// CHECK: step 0 initial: full (the first check) {{.*}} ok
// CHECK: step 1 record_body_prefer_the_later_file: refresh (3 of 33 files, 0 pending) {{.*}} ok
// CHECK: step 4 conformance_broken_prefer_the_later_file: refresh {{.*}} ok
// CHECK: modes: full 1, refresh 6; 7 steps

// The control: KAIRO_LIVE_PREFER_UNORDERED re-checks the preferred file at
// once. The first use moves, the live check sees it and takes a whole check
// (still equal to a fresh run: that check is what kept `prefer` off).
// RUN: rm -rf %t.c && mkdir -p %t.c/p && cp -r %S/Inputs/live %t.c/p/s
// RUN: env KAIRO_LIVE_PREFER_UNORDERED=1 python3 %S/../../../Scripts/incr_replay_check.py --kairo %kairo_bin --root %t.c/p --entry s/main.k --flag=-I --flag=s --flag=--threads=2 --flag=--incr-replay-in-place --two-tier --overlay --script %S/Inputs/live_prefer.replay --scratch %t.c/scratch | %FileCheck %s --check-prefix=RAW --implicit-check-not=DIFFERS
// RAW: step 1 record_body_prefer_the_later_file: full (the edited files now use an instance before the kept file that used it first) {{.*}} ok
// RAW: modes: full 4, refresh 3; 7 steps

// Preference where no first use is at stake, and with the replaced trees
// poisoned: Inputs/plan, a leaf's importers re-checked towards the entry
// and towards the later of two importers.
// RUN: rm -rf %t.p && mkdir -p %t.p/p && cp -r %S/Inputs/plan %t.p/p/s
// RUN: env KAIRO_LIVE_POISON=1 python3 %S/../../../Scripts/incr_replay_check.py --kairo %kairo_bin --root %t.p/p --entry s/main.k --flag=-I --flag=s --flag=--threads=2 --flag=--incr-replay-in-place --two-tier --overlay --script %S/Inputs/plan_prefer.replay --scratch %t.p/scratch | %FileCheck %s --check-prefix=PLAN --implicit-check-not=DIFFERS
// PLAN: modes: full 1, refresh 4; 5 steps
