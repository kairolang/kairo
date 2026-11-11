// ktextract's messages name archive entries (std::string) and the paths on
// its command line (C strings). The f-string formatter prints a value of a
// foreign type it does not know as "<type> @ <address>", which is what these
// messages showed: each must print the name itself.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %S/../../../Extras/KaTAR/KTDecompress.k -I %S/../../../Extras/KaTAR -o %t.d/ktextract
// RUN: { python3 -I %S/Inputs/messages_text.py %t.d/ktextract %t.d/work || true; } | %FileCheck %s
// CHECK-NOT: @ 0x
// CHECK: extracted: top.txt (5 bytes)
// CHECK: 1 files written to {{.*}}dest.
// CHECK: refusing unsafe entry '../bad': '..' component
// CHECK: cannot open '{{.*}}missing.ktar'
// CHECK-NOT: @ 0x
