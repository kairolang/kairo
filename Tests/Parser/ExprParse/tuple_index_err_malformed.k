// RUN: { %kairo %s --syntax-only 2>&1 1>/dev/null || true; } | %FileCheck %s --check-prefix=ERR
// A tuple index is a plain decimal ordinal. A prefix, suffix, digit separator
// or leading zero each has a plausible-but-wrong reading, so each is rejected
// rather than silently truncated to a number.
// ERR: :9:3: error [S054E]: tuple index must be a plain decimal integer with no prefix, suffix, digit separator, or leading zero
// ERR: :10:3: error [S054E]: tuple index must be a plain decimal integer with no prefix, suffix, digit separator, or leading zero
// ERR: :11:3: error [S054E]: tuple index must be a plain decimal integer with no prefix, suffix, digit separator, or leading zero
// ERR: :12:3: error [S054E]: tuple index must be a plain decimal integer with no prefix, suffix, digit separator, or leading zero
t.01
t.0x1
t.1u8
t.1_0
