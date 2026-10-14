// --preserve-comments keeps comment tokens in the stream, and they must carry
// their real source text, not a placeholder. Without the flag the comment is
// dropped before anything downstream sees it.

// kept-line-comment
fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --dump-preprocessed --preserve-comments | %FileCheck %s --check-prefix=ON
// ON: // kept-line-comment
// RUN: %kairo %s --dump-preprocessed | %FileCheck %s --check-prefix=OFF
// OFF-NOT: kept-line-comment
