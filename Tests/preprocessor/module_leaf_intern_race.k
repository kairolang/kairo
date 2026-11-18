// A fuzzer crash: std::bad_alloc copying the module path's leaf name in
// PreProcessor::_walk_one. PreprocessorSymbolTable::resolve handed out a
// pointer into a `vec::<string>` and dropped its lock; a wave task interning
// a new name on another thread regrew the vector, and the copy read a length
// out of a freed slot. Names now live in their own allocations. The race is
// timing-dependent and did not reproduce in isolation, so all this can
// assert is that the input gets its ordinary diagnostic and no crash.

fn Test ( ) { var p = b == = q ; }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --syntax-only 2>&1 || true; } | %FileCheck %s --implicit-check-not=PLEASE --implicit-check-not=Sanitizer --implicit-check-not=bad_alloc
// CHECK: module_leaf_intern_race.k:9:28: error [S052E]: expected expression, found '='
