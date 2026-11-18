// A diagnostic that names an imported C++ type Kairo cannot spell natively
// prints clang's spelling of it, never a placeholder like "<ffi type>".
ffi "c++" import "opaque_type_spelling.h"

fn bad() {
    take_slot(3);
    var i: i32 = make_slot();
}

// --- lit wiring ---
// RUN: { %kairo --type-check-only %s 2>&1 || true; } | %FileCheck %s --implicit-check-not='<ffi type>'
// CHECK: opaque_type_spelling.k:6:5: error [SC063E]: no matching overload for call to 'take_slot'
// CHECK: note [I900N]: candidate not viable: cannot convert argument of type '<literal>' to parameter 's' of type 'Slot<64>'
// CHECK: opaque_type_spelling.k:7:18: error [SC028E]: cannot convert 'Slot<64>' to 'i32'
