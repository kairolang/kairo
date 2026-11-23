// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
//
// SC005W says which rule a name broke. `__x` and `_Upper` are reserved
// by C++ at every scope ([lex.name]/3). A plain `_lower` is reserved by C++
// only at global scope, and Kairo reports it only where C++ code can name
// the declaration (pub, or prot under a module.k); this file has no module.k,
// so the private field, the parameter and the local below draw nothing.
// No case is called "reserved for the implementation in C++".

class <T> Node {
    var _next: i32
    var __raw: i32
    var _Tag: i32
}

fn f(_lead: i32) -> i32 {
    var _tmp = _lead
    return _tmp
}

// CHECK-DAG: cxx_reserved_message.k:12:9: warning [SC005W]: field name is reserved by C++ at every scope: contains a double underscore
// CHECK-DAG: cxx_reserved_message.k:13:9: warning [SC005W]: field name is reserved by C++ at every scope: begins with an underscore followed by an uppercase letter
// CHECK-NOT: reserved for the implementation

// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=LEAD
// LEAD-NOT: begins with an underscore,
