// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
//
// SC005W says which rule a name broke. `__x` and `_Upper` are reserved
// by C++ at every scope ([lex.name]/3). A plain `_lower` is reserved by C++
// only at global scope; a field, parameter or local spelled so is legal C++,
// and Kairo refuses it on its own account, at every scope on purpose. The
// message used to call every case "reserved for the implementation in C++",
// which sent readers looking for a C++ rule that does not apply to members.

class <T> Node {
    var _next: i32
    var __raw: i32
    var _Tag: i32
}

fn f(_lead: i32) -> i32 {
    var _tmp = _lead
    return _tmp
}

// CHECK-DAG: cxx_reserved_message.k:11:9: warning [SC005W]: field name begins with an underscore; Kairo reserves leading-underscore names at every scope for C++ interop
// CHECK-DAG: cxx_reserved_message.k:12:9: warning [SC005W]: field name is reserved by C++ at every scope: contains a double underscore
// CHECK-DAG: cxx_reserved_message.k:13:9: warning [SC005W]: field name is reserved by C++ at every scope: begins with an underscore followed by an uppercase letter
// CHECK-DAG: cxx_reserved_message.k:16:6: warning [SC005W]: parameter name begins with an underscore; Kairo reserves
// CHECK-DAG: cxx_reserved_message.k:17:9: warning [SC005W]: variable name begins with an underscore; Kairo reserves
// CHECK-NOT: reserved for the implementation
