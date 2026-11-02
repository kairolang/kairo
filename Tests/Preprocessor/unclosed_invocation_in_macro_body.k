// A macro body holding an unclosed invocation of itself. Expanding `ping!(42)`
// splices `ping! ( }`, and the invocation scan looked for the closing `)`
// until TkEof -- but lookahead past a splice frame answers TkUnknown forever,
// so the preprocessor spun. Running out of the frame now ends the scan: no
// invocation, and the tokens go to the parser like any other.

macro ping! ( x ) {
    ping! ( }

ping! ( 42 )

// --- lit wiring -----------------------------------------------------------
// REQUIRES: shell
// RUN: timeout 10 %kairo %s --syntax-only > %t.out 2>&1; test $? -eq 1
// RUN: %FileCheck %s --input-file=%t.out --implicit-check-not=PLEASE --implicit-check-not=Sanitizer
// CHECK: unclosed_invocation_in_macro_body.k:10:1: error [S052E]: expected expression after '('
