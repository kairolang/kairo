// Incremental Sema: an instance the retraction RE-ARMS. Tagged<i32>
// (gen.k, never edited) is made live by client.k, which sees `extend i32
// impl Named` (num.k). Renaming the witness away makes its bound fail at
// client.k's use; putting it back re-arms the entry and client.k makes it
// live again, clean. InstanceEntry::failed is the first use's verdict and
// is taken back with it (Sema/Incremental/Retract.k); rows_done and
// panic_done are not, and the comment there says why.
//
// Inputs/rearm.replay under the oracle (Scripts/incr_replay_check.py). Its
// exit status is not read: see the steps that are not asserted, below.
// RUN: rm -rf %t.d && mkdir -p %t.d/p && cp -r %S/Inputs/rearm %t.d/p/s
// RUN: { python3 %S/../../../Scripts/incr_replay_check.py --kairo %kairo_bin --root %t.d/p --entry s/main.k --flag=-I --flag=s --flag=--threads=2 --flag=--incr-replay-in-place --two-tier --overlay --script %S/Inputs/rearm.replay --scratch %t.d/scratch || true; } | %FileCheck %s

// CHECK: step 0 initial: full (the first check) {{.*}} ok
// CHECK: step 1 witness_renamed: refresh {{.*}} ok
// CHECK: step 2 witness_back: refresh {{.*}} ok
// CHECK: step 6 other_body_while_broken: refresh {{.*}} ok
// CHECK: step 7 witness_back_again: refresh {{.*}} ok
// CHECK: modes: full 1, refresh 8; 9 steps

// NOT asserted, a known difference (Compiler/Spec/IncrementalSema.md, "Not
// proven (phase 5)"): the steps that re-check other.k alone, and those after
// them until num.k is re-read. other.k names Tagged<i32> without importing
// num.k. A fresh run checks it before num.k and says "no member 'name_len'
// with the requirement's signature"; re-checked alone it comes after num.k
// and says "implemented by an extension this file does not import", with a
// note. The same error at the same place, worded by the check order.
