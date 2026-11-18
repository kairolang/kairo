// kals carries multibyte UTF-8 through whole: a project directory and a C++
// source name with non-ASCII characters reach the clangd bridge's `.clangd`
// (its PathMatch regex and quoted words), and non-ASCII names and doc text
// reach the hovers, without a character cut in two. Driven by
// inputs/multibyte_text.py over a scripted LSP session.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: python3 %S/inputs/multibyte_text.py %lsp_dev %kals | %FileCheck %s
// CHECK: .clangd written: yes
// CHECK-NEXT: clangd: PathMatch: ['bé\.cc']
// CHECK-NEXT: root in .clangd: yes
// CHECK-NEXT: diagnostics: 0
// CHECK-NEXT: hover fn: ```kairo | pub fn größe(n: i32) -> i32 | ``` | --- | Größe in Zoll ☃.
// CHECK-NEXT: hover class: ```kairo | pub class Café { |     var preis: i32 | } | ``` | size 4 bytes, align 4 | --- | Ein Café, naïve.
// CHECK-NEXT: clean shutdown: yes
