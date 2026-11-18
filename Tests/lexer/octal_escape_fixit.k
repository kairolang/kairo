// An octal escape outside a byte string is accepted with a warning that
// names the hex escape of the same value, and a fix-it that writes it. Above
// 0xFF there is no hex form: the warning says so, and the error follows. In
// a byte string an octal escape is a byte and nothing is reported.

fn f() {
    var esc  = "\033[0m"
    var nul  = '\0'
    var big  = "\777"
    var fine = b"\033\0"
}

// --- lit wiring ---
// RUN: { %kairo %s --syntax-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="warning ["
// CHECK:      {{.*}}:7:17: warning [S025W]: octal escape '\033' outside a byte string; write '\x1b' (octal escapes are for byte strings, b"...")
// CHECK-NEXT: fix-it:"{{.*}}octal_escape_fixit.k":{7:17-7:21}:"\\x1b"
// CHECK:      {{.*}}:8:17: warning [S025W]: octal escape '\0' outside a byte string; write '\x00' (octal escapes are for byte strings, b"...")
// CHECK-NEXT: fix-it:"{{.*}}octal_escape_fixit.k":{8:17-8:19}:"\\x00"
// CHECK:      {{.*}}:9:17: warning [S025W]: octal escape '\777' outside a byte string; octal escapes are for byte strings (b"...")
// CHECK-NEXT: {{.*}}:9:17: error [S027E]: octal escape '\777' is out of byte range (0-255, i.e., \0-\377)
