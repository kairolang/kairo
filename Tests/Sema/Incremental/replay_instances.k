// Incremental Sema, phase 4, re-checking in place: instances two files
// share. a.k and b.k do not import each other and name the same instances
// of g.k's generics; a.k is checked first, so the once-only conformance
// report ('Sq' does not conform to 'Shape') is a.k's.
//
// A re-check of a.k alone has to report it again (the registry's entry is
// kept, since b.k holds its node, and re-armed: Sema/Incremental/Retract.k).
// When a.k stops naming the instance the report moves to b.k, which was not
// edited; when a.k names it again it moves back. Neither can be had by
// re-checking a.k, so both are full checks that say so. Every step equals a
// fresh run (Scripts/incr_replay_check.py).

// RUN: rm -rf %t.d && mkdir -p %t.d/p && cp -r %S/Inputs/live %t.d/p/s
// RUN: python3 %S/../../../Scripts/incr_replay_check.py --kairo %kairo_bin --root %t.d/p --entry s/main.k --flag=-I --flag=s --flag=--threads=2 --flag=--incr-replay-in-place --script %S/Inputs/live.replay --scratch %t.d/scratch | %FileCheck %s --implicit-check-not=DIFFERS

// CHECK: step 1 a_body: refresh (2 of {{[0-9]+}} files) {{.*}} ok
// CHECK: step 2 b_body: refresh (2 of {{[0-9]+}} files) {{.*}} ok
// CHECK: step 3 a_stops_naming_it: full (an instance the edited files used first is now used first by a kept file) {{.*}} ok
// CHECK: step 4 b_body_again: refresh {{.*}} ok
// CHECK: step 5 a_names_it_again: full (the edited files now use an instance before the kept file that used it first) {{.*}} ok
// CHECK: step 6 conformance_fixed: refresh (4 of {{[0-9]+}} files) {{.*}} ok
// CHECK: step 7 a_body_clean: refresh {{.*}} ok
// CHECK: step 8 generic_body: refresh (4 of {{[0-9]+}} files) {{.*}} ok
// CHECK: step 9 conformance_broken: refresh {{.*}} ok
// CHECK: step 10 main_body: refresh (1 of {{[0-9]+}} files) {{.*}} ok
// CHECK: modes: full 3, refresh 8; 11 steps
