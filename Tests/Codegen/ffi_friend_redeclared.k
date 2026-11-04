// O29: a friend function also declared at namespace scope was imported as a
// hidden friend and spelled bare (`begin(...)`), which clang resolves to
// std::begin ("use of undeclared identifier 'begin'"). Redeclared outside the
// class it is a namespace member and is spelled qualified.
ffi "c++" import "ffi_friend_redeclared.h"

fn main() -> i32 {
    var a = ns::sub::begin("A")
    return a.x - 65
}

// --- lit wiring ---
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: { %kairo %s -o %t.exe --cache-dir %t.d 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: %t.exe
// DIAG-NOT: CL001E
