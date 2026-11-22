// A type error through an allocation attribute is reported at the attribute
// and names it: a keyword value of the wrong type fails overload resolution
// for the alloc.k function behind it (the note is at that parameter), and an
// `in:` type that is not an allocator fails the function's `Allocator` bound.

class Box {
    pub var v: i32
    pub fn Box(self, v: i32) { self.v = v }
}

class NotAnAllocator { }

fn bad() {
    var unsafe *a = @alloc(size: "x", align: 8)
    var *b = @create(in: NotAnAllocator) Box(1)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error ["
// DIAG: alloc_attr_type_errors.k:14:21: error [SC063E]: no matching overload for call to '@alloc'
// DIAG-NEXT: {{.*}}alloc_raw.k:{{[0-9]+}}:{{[0-9]+}}: note [I900N]: candidate not viable: cannot convert argument of type 'string' to parameter 'size' of type 'usize'
// DIAG: alloc_attr_type_errors.k:15:14: error [SC162E]: 'NotAnAllocator' does not conform to 'Allocator': no member 'alloc' with the requirement's signature
// DIAG-NEXT: {{.*}}alloc.k:{{[0-9]+}}:{{[0-9]+}}: note [I900N]: required by this bound
// DIAG-NEXT: {{.*}}alloc_raw.k:{{[0-9]+}}:{{[0-9]+}}: note [I900N]: 'alloc' is required here
