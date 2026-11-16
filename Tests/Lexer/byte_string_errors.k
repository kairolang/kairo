// Every error a byte string literal reports, each on its own line, and the
// forms it takes silently. An escape error makes the literal an error token,
// as it does in a string (the S063E that follows); the errors that are a
// byte string's own (S097E) leave it one token, so nothing follows them.

fn bad() {
    var u_small  = b"\u0041"
    var u_big    = b"\U00000041"
    var bksp     = b"\b"
    var oct_big  = b"\777"
    var nonascii = b"café ü"
    var raw_br   = br"a\b"
    var raw_rb   = rb"a\b"
    var fmt_bf   = bf"a{x}"
    var fmt_fb   = fb"a{x}"
    var suffix   = b"x"_km
    var mix_bs   = b"a" "b"
    var mix_sb   = "a" b"b"
}

fn good() {
    var simple = b"\n\r\t\v\f\a\'\"\\"
    var hex    = b"\x00\x41\xff"
    var octal  = b"\0\033\377"
    var chain  = b"ab" b"cd"
        b"ef"
    var triple = b"""one "two" three"""
    var empty  = b""
}

// --- lit wiring ---
// RUN: { %kairo %s --syntax-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: {{.*}}:7:22: error [S029E]: unicode escape '\u' is not valid in a byte string; use '\x' for raw byte values
// CHECK: {{.*}}:8:22: error [S029E]: unicode escape '\U' is not valid in a byte string; use '\x' for raw byte values
// CHECK: {{.*}}:9:22: error [S032E]: '\b' (backspace) escape is not valid in a byte string; use '\x08' instead
// CHECK: {{.*}}:10:22: error [S027E]: octal escape '\777' is out of byte range (0-255, i.e., \0-\377)
// CHECK: {{.*}}:11:25: error [S097E]: non-ASCII character in a byte string; write its bytes as '\xNN' escapes
// CHECK: {{.*}}:11:28: error [S097E]: non-ASCII character in a byte string; write its bytes as '\xNN' escapes
// CHECK: {{.*}}:12:20: error [S097E]: a raw byte string is not supported: write b"..." and escape each backslash
// CHECK: {{.*}}:13:20: error [S097E]: a raw byte string is not supported: write b"..." and escape each backslash
// CHECK: {{.*}}:14:20: error [S097E]: a byte string cannot be a format string: 'b' and 'f' do not combine
// CHECK: {{.*}}:15:20: error [S097E]: a byte string cannot be a format string: 'b' and 'f' do not combine
// CHECK: {{.*}}:16:24: error [S097E]: a byte string takes no literal suffix
// CHECK: {{.*}}:17:25: error [S097E]: a byte string and a string cannot be joined: every literal of a chain is b"...", or none is
// CHECK: {{.*}}:18:25: error [S097E]: a byte string and a string cannot be joined: every literal of a chain is b"...", or none is
// CHECK: {{.*}}:7:21: error [S063E]: unexpected token found where 'string' expected
// CHECK: {{.*}}:8:21: error [S063E]: unexpected token found where 'string' expected
// CHECK: {{.*}}:9:21: error [S063E]: unexpected token found where 'string' expected
// CHECK: {{.*}}:10:21: error [S063E]: unexpected token found where 'string' expected
