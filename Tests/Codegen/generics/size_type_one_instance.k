// `usize` is a type of its own to Kairo, but on Linux size_t IS u64's
// `unsigned long`: `Box<usize>` and `Box<u64>` are two Kairo instances and
// one C++ class, so explicitly instantiating both was clang's "duplicate
// explicit instantiation of 'Box<unsigned long>'" (P256). One line is
// written per C++ entity, nested and function instances alike.
class <T> Box { pub var v: T }
class <T> Pair { pub var a: T  pub var b: T }
fn <T> id(x: T) -> T { return x }

fn main() -> i32 {
    var a = Box<usize>()
    var b = Box<u64>()
    var c = Box<Pair<usize>>()
    var d = Box<Pair<u64>>()
    var e = Box<isize>()
    var f = Box<i64>()
    var x: usize = 6
    var y: u64 = 4
    var n = id(x) + (id(y) as usize)
    return (n as i32) - 3
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR-LABEL: CODEGEN C++: {{.*}}size_type_one_instance.k
// Six Kairo instances of Box, three C++ classes: three lines.
// IR-COUNT-3: {{^}}template class{{.*}}::Box<
// IR-NOT:     {{^}}template class{{.*}}::Box<
// One `id` line for id<usize> and id<u64>.
// IR-COUNT-1: {{^}}template {{.*}}::id<
// IR-NOT:     {{^}}template {{.*}}::id<

// REQUIRES: clang, host-linux, host-x86_64
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 7
