// A specialization written beside its primary in another module is seen by
// every TU that calls the primary: an importer's call at its arguments runs
// it, and so does a C++ host that includes the module. Written in a file of
// its own, away from its primary, a specialization has no primary in scope
// (R042E), as a record's has.

// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: cd %S/Inputs/fn_spec && { %kairo bad.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=BAD
// BAD: bad.k:6:{{[0-9]+}}: error [R042E]: 'pick' is declared as a specialization, but no primary template named 'pick' is visible here
// BAD-NOT: error

// RUN: cd %S/Inputs/fn_spec && { %kairo app.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}
// RUN: cd %S/Inputs/fn_spec && %kairo sp.k --type-check-only --emit-headers %t.d/h
// RUN: cat %t.d/h/*.hh | %FileCheck %s --check-prefix=HDR
// HDR: template{{ ?}}<class T> signed int pick() noexcept;
// HDR: template{{ ?}}<>{{.*}} signed int pick<signed int>() noexcept;

// REQUIRES: clang
// RUN: cd %S/Inputs/fn_spec && %kairo app.k -o %t.d/app --cache-dir %t.d/c1
// RUN: %t.d/app
// REQUIRES: kcc
// RUN: cd %S/Inputs/fn_spec && %kcc host.cpp -o %t.d/host
// RUN: %t.d/host
