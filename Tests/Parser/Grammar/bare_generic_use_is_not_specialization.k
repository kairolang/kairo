// Relaxing the head must not make every `Name<...>` a specialization: with
// neither a `<>` marker nor a param list there is nothing to specialize.
// RUN: { %kairo %s --syntax-only 2>&1 1>/dev/null || true; } | %FileCheck %s --check-prefix=ERR
// ERR: error
struct NS<i32> { var v: i32 }
