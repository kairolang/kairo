// A specialization written beside its primary in another module is seen by
// every TU that calls the primary: an importer's call at its arguments runs
// it, and so does a C++ host that includes the module. A function
// specialization may also be written in another module than its primary
// (fn_spec_other_module.k runs one).

// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: cd %S/inputs/fn_spec && { %kairo bad.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=BAD --allow-empty
// BAD-NOT: error

// RUN: cd %S/inputs/fn_spec && { %kairo app.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}
// RUN: cd %S/inputs/fn_spec && %kairo sp.k --type-check-only --emit-headers %t.d/h
// RUN: cat %t.d/h/*.hh | %FileCheck %s --check-prefix=HDR
// HDR: template{{ ?}}<class T> signed int pick() noexcept;
// HDR: template{{ ?}}<>{{.*}} signed int pick<signed int>() noexcept;

// REQUIRES: clang
// RUN: cd %S/inputs/fn_spec && %kairo app.k -o %t.d/app --cache-dir %t.d/c1
// RUN: %t.d/app
// REQUIRES: kcc
// RUN: cd %S/inputs/fn_spec && %kcc host.cpp -o %t.d/host
// RUN: %t.d/host
