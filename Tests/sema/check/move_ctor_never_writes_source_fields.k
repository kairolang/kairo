// SC001W fires only for a class whose value holds an address its
// destructor could release: a pointer field, directly or inside a by-value
// field whose type has no destructor of its own. A move constructor that
// only reads `other` in a class of trivially destroyed non-pointer fields
// leaves nothing to release twice, and a field whose type has a destructor
// releases what it holds itself.

var drops: i32 = 0

// Warns: a raw pointer field.
class Owns {
    var p: unsafe *i32

    fn Owns(self) { self.p = &null }
    @move fn Owns(self, other: Self) { self.p = other.p }
    fn op finally(self) { drops = drops + 1 }
}

struct Handle {
    var p: unsafe *i32
}

// Warns: the pointer sits inside a trivially destroyed by-value field.
class Wraps {
    var h: Handle

    fn Wraps(self) { self.h = Handle { p: &null } }
    @move fn Wraps(self, other: Self) { self.h = other.h }
    fn op finally(self) { drops = drops + 1 }
}

// Silent: an i32 releases nothing, whatever the destructor counts.
class Counts {
    var id: i32

    fn Counts(self, id: i32) { self.id = id }
    @move fn Counts(self, other: Self) { self.id = other.id }
    fn op finally(self) { drops = drops + 1 }
}

// Silent: a string field releases its own buffer.
class Named {
    var s: string

    fn Named(self) { self.s = "a" }
    @move fn Named(self, other: Self) { self.s = other.s }
    fn op finally(self) { drops = drops + 1 }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="warning [SC001W]"
// CHECK: move_ctor_never_writes_source_fields.k:15:{{[0-9]+}}: warning [SC001W]: the '@move' constructor of 'Owns' never writes 'other'
// CHECK: move_ctor_never_writes_source_fields.k:28:{{[0-9]+}}: warning [SC001W]: the '@move' constructor of 'Wraps' never writes 'other'
