// An empty `main` builds for armv7-windows-gnu, with and without `-g`: the
// object is produced and the link yields an image (the backend does not
// abort on the CodeView CPU type for 32-bit ARM Windows).

fn main() -> i32 {
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-armv7-windows-gnu
// RUN: rm -rf %t.d %t.exe %t.o
// RUN: %kairo %s --target armv7-windows-gnu -c -o %t.o --cache-dir %t.d
// RUN: test -s %t.o
// RUN: %kairo %s --target armv7-windows-gnu -g -c -o %t.o --cache-dir %t.d
// RUN: test -s %t.o
// RUN: %kairo %s --target armv7-windows-gnu -g -o %t.exe --cache-dir %t.d
// RUN: test -s %t.exe
