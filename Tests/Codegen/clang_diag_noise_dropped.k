ffi "c++" import "<mutex>";

pub class Holder {
    pub var guard: cxx::std::lock_guard<cxx::std::mutex>

    pub fn Holder(self) { }
}

// A clang error in generated code is reported at its Kairo location with
// clang's own notes, but two kinds of clang text carry no information for
// a Kairo user and are dropped: a "'X' declared here" note about a Kairo
// module namespace that lands in a .k file, and the filler fix-it message
// "apply the change suggested by the backend". The member note and the
// note into the C++ library header stay.

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s -c -o %t.o --error-format=pretty --no-color 2>&1 || true; } | %FileCheck %s --implicit-check-not='apply the change suggested' --implicit-check-not="clang_diag_noise_dropped' declared here"
// CHECK: [CL001E] constructor for '{{.*}}Holder' must explicitly initialize the member 'guard'
// CHECK: member is declared here
