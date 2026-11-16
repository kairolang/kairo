// A non-ASCII character that is neither XID_Continue nor White_Space cannot
// appear outside a string, a character literal or a comment: an emoji, a
// symbol, a zero-width space, a bidirectional control. Each run of them is
// one S011E, and the name they stand in is still one identifier, so nothing
// else is reported. A character that may continue a name but not start one
// (a combining mark, a non-ASCII digit) is S011E at the start of a name.

fn f() -> i32 {
    var 😀 = 1
    var na😀🚀me = 2
    var zw​ = 3
    var bidi‮ = 4
    var ́acute = 5
    var ٣three = 6
    var ok = "😀 → ​" // 😀 → in a string and a comment
    return 0
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: {{.*}}:9:9: error [S011E]: character U+1F600 cannot appear in an identifier, or anywhere outside a string, a character literal or a comment
// CHECK: {{.*}}:10:11: error [S011E]: character U+1F600 cannot appear in an identifier, or anywhere outside a string, a character literal or a comment
// CHECK: {{.*}}:11:11: error [S011E]: character U+200B cannot appear in an identifier, or anywhere outside a string, a character literal or a comment
// CHECK: {{.*}}:12:13: error [S011E]: character U+202E cannot appear in an identifier, or anywhere outside a string, a character literal or a comment
// CHECK: {{.*}}:13:9: error [S011E]: character U+0301 cannot start an identifier
// CHECK: {{.*}}:14:9: error [S011E]: character U+0663 cannot start an identifier
