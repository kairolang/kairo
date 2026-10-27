// What can be panicked (PANIC.md §1.5): ANY movable, complete value type --
// no base class, no required operator (`op panic` is optional). An error
// is returned and propagated by value, so a type that cannot be moved,
// `void`, or an incomplete type is an error wherever a panic names it: at
// a `panic`, in a declared set, at a `catch`. Primitives, strings and
// pointers are fine.

class Pinned {
    var n: i32
    fn Pinned(self) { self.n = 0 }
    @move fn Pinned(self, other: Pinned) = delete
}

class Later;

struct Plain { var n: i32 }

fn nothing() { }

fn raises_pinned() panic -> i32 { panic Pinned() }

fn raises_void() panic -> i32 { panic nothing() }

fn declares_pinned() panic(Pinned, Plain) -> i32 { return 0 }

fn declares_later() panic(*Later, Later) -> i32 { return 0 }

fn catches(x: i32) -> i32 {
    try {
        return declares_pinned()
    } catch e: Pinned {
        return 1
    } catch {
        return 2
    }
}

// Accepted: no type here needs anything but to be a movable value.
fn raises_values(x: i32) panic -> i32 {
    if x == 0 { panic 7 }
    if x == 1 { panic "message" }
    if x == 2 { panic Plain { n: x } }
    return x
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: payload_types.k:20:41: error [SC001E]: type 'Pinned' cannot be panicked: it is not movable; an error is returned and propagated by value (its move constructor is deleted)
// CHECK-NEXT: payload_types.k:8:1: note [SC001N]: 'Pinned' is declared here
// CHECK: payload_types.k:22:39: error [SC001E]: type 'void' cannot be panicked: 'void' is not a value
// CHECK: payload_types.k:24:28: error [SC001E]: type 'Pinned' cannot be panicked: it is not movable; an error is returned and propagated by value (its move constructor is deleted)
// CHECK-NEXT: payload_types.k:8:1: note [SC001N]: 'Pinned' is declared here
// CHECK: payload_types.k:26:35: error [SC001E]: type 'Later' cannot be panicked: it is incomplete; an error is held by value, so its size must be known
// CHECK-NEXT: payload_types.k:14:1: note [SC001N]: 'Later' is declared here
// CHECK: payload_types.k:31:16: error [SC001E]: type 'Pinned' cannot be caught: it is not movable; an error is returned and propagated by value (its move constructor is deleted)
// CHECK-NEXT: payload_types.k:8:1: note [SC001N]: 'Pinned' is declared here
