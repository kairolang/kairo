// kcc maps clang's link-shape words to the link of the target's flavor:
// -dynamiclib is a shared library (`-shared` for ELF, `-dylib` for Mach-O),
// -framework / -weak_framework reach a Mach-O link as given, and -rdynamic
// is `--export-dynamic` for ELF and `-export_dynamic` for Mach-O (ld64 has no
// `--export-dynamic`).

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc, default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: echo 'int f(void) { return 1; }' > %t.d/t.c

// ELF.
// RUN: %kcc -### -dynamiclib %t.d/t.c -o %t.d/x 2>&1 | %FileCheck %s --check-prefix=ELFLIB
// ELFLIB: ld.lld {{.*}}-shared
// RUN: %kcc -### -rdynamic %t.d/t.c -o %t.d/x 2>&1 | %FileCheck %s --check-prefix=ELFDYN
// ELFDYN: ld.lld {{.*}}--export-dynamic

// A Mach-O link needs the macOS sysroot.
// RUN: %if sysroot-x86_64-macosx %{ %kcc --target=x86_64-apple-macosx -### -dynamiclib %t.d/t.c -framework Foo -weak_framework Bar -o %t.d/x 2>&1 | %FileCheck %s --check-prefix=MACHO %}
// MACHO: ld64.lld {{.*}}-dylib
// MACHO-SAME: -framework Foo -weak_framework Bar
// MACHO-NOT: --shared
// RUN: %if sysroot-x86_64-macosx %{ %kcc --target=x86_64-apple-macosx -### -rdynamic %t.d/t.c -o %t.d/x 2>&1 | %FileCheck %s --check-prefix=MACHODYN %}
// MACHODYN: ld64.lld {{.*}}-export_dynamic
// MACHODYN-NOT: --export-dynamic
