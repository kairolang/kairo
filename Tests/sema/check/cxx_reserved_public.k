// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
//
// A plain leading underscore (SC005W) is reported on every kind of `pub`
// declaration, in a file with or without a module.k: C++ code can name all of
// them. This file has no module.k, so its unmarked declarations stay quiet.

pub fn _pub_function() -> i32 {
    return 1
}

pub var _pub_global: i32 = 2

pub class _pub_class {
    pub var _pub_field: i32 = 0
    pub fn _pub_method(self) -> i32 {
        return self._pub_field
    }
    pub static fn _pub_static() -> i32 {
        return 3
    }
}

pub struct _pub_struct {
    pub var x: i32 = 0
}

pub enum _pub_enum {
    A,
}

pub interface _pub_interface {
    fn get(self) -> i32
}

pub type _pub_alias = i32

fn _quiet_function() -> i32 {
    return 4
}

// CHECK-DAG: cxx_reserved_public.k:7:8: warning [SC005W]: function name begins with an underscore, and C++ code can name it
// CHECK-DAG: cxx_reserved_public.k:11:9: warning [SC005W]: variable name begins with an underscore, and C++ code can name it
// CHECK-DAG: cxx_reserved_public.k:13:11: warning [SC005W]: class name begins with an underscore, and C++ code can name it
// CHECK-DAG: cxx_reserved_public.k:14:13: warning [SC005W]: field name begins with an underscore, and C++ code can name it
// CHECK-DAG: cxx_reserved_public.k:15:12: warning [SC005W]: function name begins with an underscore, and C++ code can name it
// CHECK-DAG: cxx_reserved_public.k:18:19: warning [SC005W]: function name begins with an underscore, and C++ code can name it
// CHECK-DAG: cxx_reserved_public.k:23:12: warning [SC005W]: struct name begins with an underscore, and C++ code can name it
// CHECK-DAG: cxx_reserved_public.k:27:10: warning [SC005W]: enum name begins with an underscore, and C++ code can name it
// CHECK-DAG: cxx_reserved_public.k:31:15: warning [SC005W]: interface name begins with an underscore, and C++ code can name it
// CHECK-DAG: cxx_reserved_public.k:35:10: warning [SC005W]: type alias name begins with an underscore, and C++ code can name it
// CHECK-NOT: cxx_reserved_public.k:37:
