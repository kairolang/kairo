// --error-format=json prints one JSON object per diagnostic on a line of its
// own: file, line, col, severity, code, message.
fn main() -> i32 { var a: i32 = u1; return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --error-format=json 2>&1 || true; } | %FileCheck %s
// CHECK: {"file":"{{.*}}error_format_json.k","line":{{[0-9]+}},"col":{{[0-9]+}},"severity":"error","code":"R020E","message":"use of undeclared identifier 'u1'"}
