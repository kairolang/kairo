// A brace initializer of a class or struct whose only constructor is
// a transfer constructor (`@copy` or `@move`, defaulted or deleted) is not
// an internal error in EmitIR ("initializer on a record with a constructor"). C++ makes
// any user-declared constructor a non-aggregate, so it is SC088E, as it is
// once any other constructor exists. The note names the transfer
// constructor: there is no ordinary one to call.

class CopyOnly {
    var x: i32 = 0
    @copy fn CopyOnly(self, const other: Self) = default
}

class MoveOnly {
    var x: i32 = 0
    @move fn MoveOnly(self, other: Self) = default
}

class CopyDeleted {
    var x: i32 = 0
    @copy fn CopyDeleted(self, const other: Self) = delete
}

struct SCopy {
    var x: i32 = 0
    @copy fn SCopy(self, const other: Self) = default
}

// The ordinary constructor is preferred for the note.
class Both {
    var x: i32 = 0
    @copy fn Both(self, const other: Self) = default
    fn Both(self) = default
}

fn main() -> i32 {
    var a = CopyOnly { x: 1 }
    var b = MoveOnly { x: 1 }
    var c = CopyDeleted { x: 1 }
    var d = SCopy { x: 1 }
    var e = Both { x: 1 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: brace_init_transfer_ctor.k:36:13: error [SC088E]: 'CopyOnly' declares a constructor, so it cannot be built with a brace initializer
// CHECK: brace_init_transfer_ctor.k:10:11: note [I900N]: 'CopyOnly' declares a transfer constructor here; give it a constructor to call, or remove this one to build it from braces
// CHECK: brace_init_transfer_ctor.k:37:13: error [SC088E]: 'MoveOnly' declares a constructor
// CHECK: brace_init_transfer_ctor.k:15:11: note [I900N]: 'MoveOnly' declares a transfer constructor here
// CHECK: brace_init_transfer_ctor.k:38:13: error [SC088E]: 'CopyDeleted' declares a constructor
// CHECK: brace_init_transfer_ctor.k:20:11: note [I900N]: 'CopyDeleted' declares a transfer constructor here
// CHECK: brace_init_transfer_ctor.k:39:13: error [SC088E]: 'SCopy' declares a constructor
// CHECK: brace_init_transfer_ctor.k:25:11: note [I900N]: 'SCopy' declares a transfer constructor here
// CHECK: brace_init_transfer_ctor.k:40:13: error [SC088E]: 'Both' declares a constructor
// CHECK: brace_init_transfer_ctor.k:32:5: note [I900N]: 'Both' constructor declared here; call it instead: 'Both(...)'
