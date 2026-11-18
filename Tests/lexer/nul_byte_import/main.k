// A file is lexed more than once (the import scan, then the walk), and an
// imported file by more than one importer. Its NUL byte is reported once.

import self::lib

fn main() -> i32 {
    return lib::two()
}

// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: {{.*}}lib.k:3:14: error [S011E]: NUL byte in source; a source file is text and cannot contain U+0000
