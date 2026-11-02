// A braced value arm whose inner brace pair closes and then the file ends.
// The newline-skipping lookahead scanned from the last token index, which past
// EOF is the `}` already consumed, so it answered `}` and the recovery read the
// null cursor as that brace. The code must stay the last bytes of the file.
//
// REQUIRES: shell
// RUN: timeout 10 %kairo %s --syntax-only > %t.out 2>&1; test $? -eq 1
// RUN: %FileCheck %s --input-file=%t.out --implicit-check-not=PLEASE --implicit-check-not=Sanitizer
// CHECK: eof_in_braced_arm.k:12:8: error [S054E]: expression-form 'if' requires a final 'else'
// CHECK: eof_in_braced_arm.k:12:13: error [S073E]: value arms are written '=> expr'

return if c { { }