pub class Hidden {
    var secret: i32
    pub var shown: i32
    eval fn Hidden(self) { self.secret = 1  self.shown = 2 }
}

pub struct Runtime {
    pub var n: i32
    fn Runtime(self) { self.n = 0 }
}

pub struct Ptr {
    pub var p: *i32
    eval fn Ptr(self) { self.p = &null }
}

pub struct Inner { var v: i32 }
pub class Outer {
    pub var inner: Hidden
    eval fn Outer(self) { }
}

class <eval A: Hidden> UsesHidden { }
class <eval B: Runtime> UsesRuntime { }
class <eval C: Ptr> UsesPtr { }
class <eval D: Outer> UsesOuter { }

fn main() -> i32 { return 0 }

// EVAL.md 7e: a class is a generic value parameter's type only when it is
// structural (C++ compares such arguments member by member): the first
// field that is not `pub` (a class's unmarked field is private), points to
// mutable memory, or is of a class that is not structural, and the first
// constructor that is not `eval`, is the error, with a note at it.
// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: class_value_param_errors.k:23:16: error [SC001E]: 'Hidden' cannot be the type of a generic value parameter: its field 'secret' is not 'pub'
// CHECK-NEXT: class_value_param_errors.k:2:5: note [SC001N]: declared here
// CHECK: class_value_param_errors.k:24:16: error [SC001E]: 'Runtime' cannot be the type of a generic value parameter: a constructor of 'Runtime' is not 'eval'
// CHECK-NEXT: class_value_param_errors.k:9:5: note [SC001N]: declared here
// CHECK: class_value_param_errors.k:25:16: error [SC001E]: 'Ptr' cannot be the type of a generic value parameter: its field 'p' points to mutable memory
// CHECK-NEXT: class_value_param_errors.k:13:9: note [SC001N]: declared here
// CHECK: class_value_param_errors.k:26:16: error [SC001E]: 'Outer' cannot be the type of a generic value parameter: its field 'inner' is a 'Hidden', and its field 'secret' is not 'pub'
// CHECK-NEXT: class_value_param_errors.k:2:5: note [SC001N]: declared here
