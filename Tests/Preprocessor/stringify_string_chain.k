// A string chain (`"a" "b"`, joined adjacent literals) is one token, and
// its range now covers every segment. stringify! quotes its
// argument's source by that range, so a chain that ended the argument lost
// its later segments: `stringify!("a" "b")` was `""a""`. A chain followed by
// more tokens came out whole by accident (the slice ran to the last token).

var s = stringify!("a" "b")
var t = stringify!(x "a" "b")
var u = stringify!("a" "b" + 1)
var v = stringify!("a"
    "b")

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --dump-preprocessed | %FileCheck %s
// CHECK: var s = ""a" "b""
// CHECK: var t = "x "a" "b""
// CHECK: var u = ""a" "b" + 1"
// CHECK: var v = ""a"
// CHECK-NEXT: "b""
