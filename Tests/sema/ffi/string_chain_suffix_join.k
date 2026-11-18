// The join fix-it is offered only where joining the text keeps the bytes.
// An octal escape takes one to three digits (Lexing.md), so `"\1" "2"_len`
// is the two bytes 0x01 '2', but `"\12"_len` is one byte: no fix-it there.
// A complete escape (`\123`), an escaped backslash before digits (`\\1`)
// and a raw chain join as text. A chain that starts the file's first line
// is read at its closing quotes, never before its opening one.
ffi "c++" import "string_literal_suffix.h"

fn open() -> usize { return "\1" "2"_len }
fn full() -> usize { return "\123" "4"_len }
fn slash() -> usize { return "\\1" "2"_len }
fn raw() -> usize { return r"\1" r"2"_len }

fn main() -> i32 {
    var n = open() + full() * 10 + slash() * 100 + raw() * 1000
    return if (n == 3322) => (0) else => 1
}

// --- lit wiring ---
// RUN: rm -rf %t.dir && mkdir -p %t.dir && cp %S/string_literal_suffix.h %t.dir/
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK:      .k:9:37: warning [SC276W]:
// CHECK-NOT:  fix-it
// CHECK:      .k:10:39: warning [SC276W]:
// CHECK-NEXT: fix-it:"{{.*}}":{10:29-10:43}:"\"\\1234\"_len"
// CHECK-NEXT: .k:11:39: warning [SC276W]:
// CHECK-NEXT: fix-it:"{{.*}}":{11:30-11:43}:"\"\\\\12\"_len"
// CHECK-NEXT: .k:12:38: warning [SC276W]:
// CHECK-NEXT: fix-it:"{{.*}}":{12:28-12:42}:"r\"\\12\"_len"
//
// RUN: printf '"a" "b"_len\n' > %t.dir/first.k
// RUN: { %kairo %t.dir/first.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=FIRST
// FIRST:      first.k:1:8: warning [SC276W]:
// FIRST-NEXT: fix-it:"{{.*}}first.k":{1:1-1:12}:"\"ab\"_len"
//
// RUN: rm -rf %t.d && %kairo %s -o %t.exe --cache-dir %t.d && %t.exe
