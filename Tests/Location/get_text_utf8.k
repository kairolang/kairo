// RUN: { %kairo %s --type-check-only --print-ast=tree || true; } | %FileCheck %s
// SourceManager::get_text must return the range's UTF-8 bytes unchanged.
// Literal bodies are re-read through get_text, so a corrupted round trip shows
// up as replacement characters in the tree dump.
// CHECK: StringLiteralExpr "héllo wörld ✓"
// CHECK: StringLiteralExpr "日本語"
fn main() -> i32 {
    var a: string = "héllo wörld ✓"
    var b: string = "日本語"
    return 0
}
