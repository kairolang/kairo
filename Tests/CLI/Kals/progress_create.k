// A work-done progress token is used only after the client answered
// `window/workDoneProgress/create` without an error. A client that answers
// late sees no `$/progress` before its answer, then the begin and the end;
// a client that answers with an error sees none, and the server goes on.
// Driven by Inputs/progress_create.py over a scripted LSP session.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: python3 %S/Inputs/progress_create.py %lsp_dev %kals | %FileCheck %s
// CHECK: created: yes
// CHECK-NEXT: progress before the answer: none
// CHECK-NEXT: begin after the answer: yes
// CHECK-NEXT: end after begin: yes
// CHECK-NEXT: refused: created: yes
// CHECK-NEXT: refused: progress: none
// CHECK-NEXT: refused: analysed: yes
// CHECK-NEXT: clean shutdown: yes
