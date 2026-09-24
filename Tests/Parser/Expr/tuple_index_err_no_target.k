// RUN: { %kairo %s --syntax-only 2>&1 1>/dev/null || true; } | %FileCheck %s --check-prefix=ERR
// The diagnostic names the SEPARATOR it is complaining after, not whatever
// token the cursor happens to be sitting on.
// ERR: :5:4: error [S054E]: expected identifier or tuple index after '.' in access expression
t.0.
