// Every escape diagnostic the lexer reports, and the escapes it accepts
// silently. Each literal is on its own line, so each diagnostic's column
// shows the range it covers.

fn bad() {
    var unknown_ascii = "\q"
    var unknown_utf8  = "\é"
    var hex_short     = "\x4g"
    var u_short       = "\u12g4"
    var big_u_short   = "\U1234567g"
    var big_u_range   = "\U00110000"
    var u_surrogate   = "\uD800"
    var big_u_surr    = "\U0000DFFF"
    var octal_range   = "\777"
    var octal_warn    = "\033"
    var brace_plain   = "\{"
}

fn good() {
    var simple   = "\n\r\t\v\f\a\b\'\"\\"
    var hex      = "\x41\xff"
    var unicode  = "é\U0001F600\U0010FFFF"
    var octal    = "\0"
    var brace_f  = f"\{\}"
    var raw      = r"\q\x\u"
    var chr      = 'é'
}

// --- lit wiring ---

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:6:26: error [S033E]: unknown escape sequence '\q'
// DIAG: {{.*}}:7:26: error [S033E]: unknown escape sequence '\é'
// DIAG: {{.*}}:8:26: error [S023E]: invalid '\x' hex escape '\x4': expected exactly 2 hex digits (0-9, a-f, A-F)
// DIAG: {{.*}}:9:26: error [S028E]: invalid '\u' unicode escape '\u12': expected exactly 4 hex digits (0-9, a-f, A-F)
// DIAG: {{.*}}:10:26: error [S028E]: invalid '\U' unicode escape '\U1234567': expected exactly 8 hex digits (0-9, a-f, A-F)
// DIAG: {{.*}}:11:26: error [S030E]: unicode escape '\U00110000' is out of the valid unicode range (U+0000-U+10FFFF)
// DIAG: {{.*}}:12:26: error [S031E]: unicode escape '\uD800' encodes a surrogate code point (U+D800-U+DFFF), which is not a valid unicode scalar value
// DIAG: {{.*}}:13:26: error [S031E]: unicode escape '\U0000DFFF' encodes a surrogate code point (U+D800-U+DFFF), which is not a valid unicode scalar value
// DIAG: {{.*}}:14:26: warning [S025W]: octal escape '\777' is only valid in byte strings (b"..."); use '\u' for unicode codepoints
// DIAG: {{.*}}:14:26: error [S027E]: octal escape '\777' is out of byte range (0-255, i.e., \0-\377)
// DIAG: {{.*}}:15:26: warning [S025W]: octal escape '\033' is only valid in byte strings (b"..."); use '\u' for unicode codepoints
// DIAG: {{.*}}:16:26: warning [S022W]: '\{' and '\}' escapes are only valid inside format strings (f"..."); remove the backslash or use an f-string prefix
// DIAG-NEXT: fix-it:"{{.*}}":{16:26-16:27}:""
// DIAG: {{.*}}:23:21: warning [S025W]: octal escape '\0' is only valid in byte strings (b"..."); use '\u' for unicode codepoints
// DIAG: {{.*}}:6:25: error [S063E]: unexpected token found where 'string' expected
// DIAG: {{.*}}:7:25: error [S063E]: unexpected token found where 'string' expected
// DIAG: {{.*}}:8:25: error [S063E]: unexpected token found where 'string' expected
// DIAG: {{.*}}:9:25: error [S063E]: unexpected token found where 'string' expected
// DIAG: {{.*}}:10:25: error [S063E]: unexpected token found where 'string' expected
// DIAG: {{.*}}:11:25: error [S063E]: unexpected token found where 'string' expected
// DIAG: {{.*}}:12:25: error [S063E]: unexpected token found where 'string' expected
// DIAG: {{.*}}:13:25: error [S063E]: unexpected token found where 'string' expected
// DIAG: {{.*}}:14:25: error [S063E]: unexpected token found where 'string' expected
// END-GENERATED-CHECKS(DIAG)
