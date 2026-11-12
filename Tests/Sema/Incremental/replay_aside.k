// Incremental Sema, phase 5: a text that is tried and thrown away
// (Tooling::LiveCheck::aside and ::past_syntax; `aside` in an --incr-replay
// script). A language server has two of them per keystroke: the buffer while
// a line is half typed, which does not parse, and the buffer with a
// completion marker in it. Neither may become part of the checked graph: the
// edit is re-checked in a COPY of the process (kairo::aside_fork), the file
// alone as an edit's first tier re-checks it, and the copy ends.
//
// In the copy a file whose syntax errors are all inside function bodies is
// checked as --check-past-syntax-errors checks it (the bodies dropped); one
// with an error anywhere else is refused, and has its syntax errors alone.
//
// The oracle (Scripts/incr_replay_check.py), per aside: the diagnostics the
// copy reported for the file are the ones a fresh
// `kairo --type-check-only --check-past-syntax-errors` reports there for the
// same texts. And per step, as always: stderr and --dump-interface equal a
// fresh run's, which here also says that no aside left a trace.

// Inputs/aside.replay over Inputs/aside: errors inside one body (three texts
// in a row, as a line is typed), then the fix; an error outside every body;
// a file broken while another file's importers are queued; a file broken,
// another edited and kept, the first still broken, then fixed; the entry
// (no importers, so no queue) with an undeclared name and with a broken body.
// RUN: rm -rf %t.d && mkdir -p %t.d/p && cp -r %S/Inputs/aside %t.d/p/s
// RUN: python3 %S/../../../Scripts/incr_replay_check.py --kairo %kairo_bin --root %t.d/p --entry s/main.k --flag=-I --flag=s --flag=--threads=2 --flag=--incr-replay-in-place --two-tier --overlay --script %S/Inputs/aside.replay --scratch %t.d/scratch --expect-aside break_outside_a_body=refused --expect-aside break_then_edit_another_file=refresh,refresh --expect-aside try_the_entry=refresh,refresh | %FileCheck %s --implicit-check-not=DIFFERS --implicit-check-not=UNEXPECTED

// CHECK: step 0 initial: full (the first check) {{.*}} ok
// CHECK: step 1 semantic_error_in_a_healthy_function: refresh {{.*}} ok
// An error in the middle of a body, a complete statement after it: checked,
// one file, and the importers are the copy's to forget.
// CHECK: step 2 break_inside_a_body: refresh {{.*}} aside lib.k refresh {{[0-9]+}} ms (1 of {{[0-9]+}} files, 2 pending); aside lib.k refresh {{.*}} aside lib.k {{.*}} ok
// CHECK: step 3 fixed_by_a_kept_edit: refresh {{.*}} ok
// CHECK: step 4 semantic_error_fixed: refresh {{.*}} ok
// CHECK: step 5 break_outside_a_body: refresh {{.*}} aside lib.k refused {{[0-9]+}} ms (a syntax error outside a function body); ok
// CHECK: step 6 kept_edit_after_it: refresh {{.*}} ok
// CHECK: step 7 break_while_importers_are_queued: refresh {{.*}} fg lib.k refresh {{.*}} aside other.k refresh {{.*}} aside other.k refresh {{.*}} ok
// CHECK: step 8 break_then_edit_another_file: refresh {{.*}} ok
// CHECK: step 9 fixed: refresh {{.*}} ok
// The entry, which leaves no queue behind it: a name nothing declares (a
// completion marker), and an error inside its body.
// CHECK: step 10 try_the_entry: refresh {{.*}} aside main.k refresh {{.*}} aside main.k refresh {{.*}} ok
// CHECK: step 11 entry_kept_edit: refresh {{.*}} ok
// CHECK: modes: full 1, refresh 11; 12 steps
