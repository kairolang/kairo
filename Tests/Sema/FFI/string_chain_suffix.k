// In a chain of adjacent string literals a suffix on ANY segment is
// the whole joined string's (the C++ rule): `"12" "3"_len` passes all three
// bytes to `operator""_len`. Before, only the head's suffix was consulted
// and a later one was recorded and dropped, so this was a plain string.
// Every chain with a suffix warns SC276W (a head-only suffix too: the same
// hazard read the other way), with a fix-it that joins the segments into
// one literal when their text can be joined; two different suffixes are
// SC277E; a chain with an f segment takes none (SC074E, any segment).
ffi "c++" import "string_literal_suffix.h"

fn later() -> usize { return "12" "3"_len }
fn head() -> usize { return "12"_len "3" }
fn both() -> usize { return "ab"_len "c"_len }
fn raw() -> usize { return r"\a" r"b"_len }
fn mixed() -> usize { return "a" r"\b"_len }
fn lines() -> usize {
    return "a"
           "bc"_len
}
@no_warn(SC276W)
fn quiet() -> usize { return "x" "y"_len }

fn main() -> i32 {
    var n = later() + head() * 10 + both() * 100 + raw() * 1000 + mixed() * 10000 + lines() * 100000 + quiet() * 1000000
    return if (n == 2333333) => (0) else => 1
}

fn bad() {
    var x = 1
    var d = "12"_len "3"_km
    var f = "a" f"{x}" "c"_len
}

// --- lit wiring ---
// RUN: rm -rf %t.dir && mkdir -p %t.dir && cp %S/string_literal_suffix.h %t.dir/
// RUN: sed -e '/^fn bad/,$d' %s > %t.dir/good.k
// RUN: { %kairo %t.dir/good.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=WARN
// WARN:      .k:11:38: warning [SC276W]: the literal suffix '_len' applies to the whole string joined from these 2 segments, not only to the segment it is written on
// WARN-NEXT: fix-it:"{{.*}}":{11:30-11:42}:"\"123\"_len"
// WARN-NEXT: .k:12:33: warning [SC276W]: the literal suffix '_len' applies
// WARN-NEXT: fix-it:"{{.*}}":{12:29-12:41}:"\"123\"_len"
// WARN-NEXT: .k:13:33: warning [SC276W]:
// WARN-NEXT: fix-it:"{{.*}}":{13:29-13:45}:"\"abc\"_len"
// WARN-NEXT: .k:14:38: warning [SC276W]:
// WARN-NEXT: fix-it:"{{.*}}":{14:28-14:42}:"r\"\\ab\"_len"
// WARN-NEXT: .k:15:39: warning [SC276W]:
// WARN-NOT:  fix-it
// WARN:      .k:18:16: warning [SC276W]: {{.*}} 2 segments
// WARN-NEXT: fix-it:"{{.*}}":{17:12-18:20}:"\"abc\"_len"
// WARN-NOT:  .k:21:
//
// RUN: rm -rf %t.d && %kairo %t.dir/good.k -o %t.exe --cache-dir %t.d
// RUN: %t.exe
//
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=BAD
// BAD:      .k:30:25: error [SC277E]: segments of one string literal have different suffixes '_len' and '_km'; a suffix applies to the whole joined string, so it can have only one
// BAD-NEXT: .k:30:17: note [SC277N]: '_len' is spelled here
// BAD:      .k:31:13: error [SC074E]: a format string cannot take the literal suffix '_len'
