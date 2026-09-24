ffi "c++" import "<mutex>";
fn take(@move m: cxx::std::mutex) { }
fn main() {
    var m = cxx::std::mutex();
    take(m);                                // expect: error cannot move a value of type 'std::mutex': its copy constructor is deleted / declares no move constructor; note type declared here
}

// --- lit wiring -----------------------------------------------------------
// `@move` into a type whose lifecycle facts say it is not movable
// (ClassLifecycle::facts_of_type -> why_not_movable).
//
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
//
// The type renders by its own name ('mutex'), as every record in a
// diagnostic does; the namespace is not spelled.
//
// DIAG:      non_movable.k:5:{{[0-9]+}}: error [SC001E]: cannot move a value of type 'mutex': it declares no move constructor and its copy constructor is deleted
// DIAG-NEXT: {{.*}}mutex.h:{{[0-9]+}}:{{[0-9]+}}: note [{{[A-Z0-9]+}}]: type declared here
// DIAG-NOT:  {{error|warning}} [
