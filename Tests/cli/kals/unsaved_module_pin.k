// A library's pin (a bare `module name` first in a module.k) is read from
// the editor's open buffer of that file when there is one, not from the
// disk: an unsaved edit that moves the pin below another declaration is an
// R064E in the module.k, an unsaved rename is seen by the files that import
// the library (and re-checks them), and neither shows after the buffer
// goes back. Driven by inputs/unsaved_module_pin.py over a scripted LSP
// session, with the live check and with a process per run.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: python3 %S/inputs/unsaved_module_pin.py %lsp_dev %kals | %FileCheck %s
// RUN: env KALS_LIVE_CHECK=0 python3 %S/inputs/unsaved_module_pin.py %lsp_dev %kals | %FileCheck %s
// CHECK: saved pin: module.k clean: yes
// CHECK-NEXT: saved pin: main.k clean: yes
// CHECK-NEXT: unsaved late pin: module.k R064E: yes
// CHECK-NEXT: unsaved rename: module.k clean: yes
// CHECK-NEXT: unsaved rename: main.k import fails: yes
// CHECK-NEXT: buffer restored: module.k clean: yes
// CHECK-NEXT: buffer restored: main.k clean: yes
// CHECK-NEXT: clean shutdown: yes
