// ktextract joins archive entry names onto the destination, so an archive
// controls where files land unless every name is validated. Each case builds a
// hostile archive by hand (Inputs/path_traversal.py) and requires the extractor
// to refuse it with a diagnostic naming the entry and to create nothing: names
// with '..', absolute or UNC roots, drive prefixes, NULs, and writes through
// symlinks already present in the destination. The KTAR format has no link
// entries of its own, so the link escape is a pre-existing destination link.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: mkdir -p %t.d
// RUN: %kairo %S/../../../Extras/KaTAR/KTDecompress.k -I %S/../../../Extras/KaTAR -o %t.d/ktextract
// RUN: rm -rf %t.d/work
// RUN: { python3 -I %S/Inputs/path_traversal.py %t.d/ktextract %t.d/work || true; } | %FileCheck %s
// CHECK-NOT: FAIL
// CHECK-DAG: PASS dotdot
// CHECK-DAG: PASS nested_dotdot
// CHECK-DAG: PASS backslash_dotdot
// CHECK-DAG: PASS absolute
// CHECK-DAG: PASS backslash_root
// CHECK-DAG: PASS unc
// CHECK-DAG: PASS drive_abs
// CHECK-DAG: PASS drive_relative
// CHECK-DAG: PASS nul_byte
// CHECK-DAG: PASS empty_name
// CHECK-DAG: PASS late_bad_entry
// CHECK-DAG: PASS symlink_dir_escape
// CHECK-DAG: PASS symlink_dangling_dir
// CHECK-DAG: PASS symlink_file_write
// CHECK-DAG: PASS abs_victim_absent
// CHECK-DAG: PASS benign
