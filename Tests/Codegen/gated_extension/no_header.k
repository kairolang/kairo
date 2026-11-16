// A file that imports the bridge but no C++ header: `string` does not
// convert to `std::string` here, although lib.k, which it imports, has the
// header. The question is asked of this file's own scope. A named member
// of the same block is missing too, and the note says what the block
// needs rather than offering an import of a file already imported.

import self::bridge::*
import self::lib::*

fn main() -> i32 {
    var s: string = "abc"
    return lib_takes(s) + (s.cxx_size() as i32)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: no_header.k:12:12: error [SC063E]: no matching overload for call to 'lib_takes'
// CHECK: candidate not viable: cannot convert argument of type 'string' to parameter 's' of type 'basic_string<c_char, char_traits<c_char>, allocator<c_char>>'
// CHECK: no_header.k:12:30: error [R025E]: no member named 'cxx_size' in 'string'
// CHECK-NEXT: bridge.k:6:1: note [I900N]: an extension of 'string' declares 'cxx_size' only in a file that declares 'cxx::std::string'; this file does not
