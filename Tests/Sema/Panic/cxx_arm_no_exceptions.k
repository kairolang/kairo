// A `catch e: cxx::...` arm catches a C++ exception (PANIC.md §3.5), which
// needs C++ exceptions: with -fno-exceptions (or on a target with no OS,
// where they default off) the arm is an error, with an edit removing it.
// A C++ type IN the panic set is a panic arm, not an exception arm, and is
// fine either way. With exceptions on (the hosted default) nothing is
// reported.
ffi "c++" import "<exception>"

fn plain(x: i32) -> i32 { return x }

fn guarded(x: i32) -> i32 {
    try {
        return plain(x)
    } catch e: cxx::std::exception {
        return -1
    }
}

fn raises(x: i32) panic(cxx::std::exception) -> i32 {
    if x < 0 { panic cxx::std::exception() }
    return x
}

fn in_set(x: i32) -> i32 {
    try { return raises(x) } catch e: cxx::std::exception { return -2 }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s -fno-exceptions --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: cxx_arm_no_exceptions.k:14:7: error [SC001E]: 'catch' of the C++ exception 'exception' in a build without C++ exceptions (-fno-exceptions, or a target with no OS)
// CHECK-NEXT: fix-it:"{{.*}}cxx_arm_no_exceptions.k":{14:7-16:6}:""
// CHECK-NEXT: {{.*}}exception{{.*}}: note [SC001N]: 'exception' is declared here, in C++
// RUN: %kairo %s --type-check-only
