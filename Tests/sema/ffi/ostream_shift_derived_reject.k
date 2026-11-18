// A shift whose left operand is not a stream is still rejected, while the
// same expressions with a derived-stream left operand type-check (a chain
// of shifts included).
ffi "c++" import "sstream"
ffi "c++" import "string"

fn main() -> i32 {
    var s = cxx::std::to_string(12345 as i32)
    var n: i32 = 3
    var os: cxx::std::ostringstream
    os << s << s
    n << s
    return 0
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not='error [' --implicit-check-not='I003E'
// CHECK: ostream_shift_derived_reject.k:12:5: error [SC063E]: no matching overload for call to 'op <<'
