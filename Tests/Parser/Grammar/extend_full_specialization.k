// `extend <>` is the full-specialization marker, exactly as on struct/class.
// The specialization arguments live in the target type.
// RUN: %kairo %s --syntax-only 2>&1 | %FileCheck %s --check-prefix=OK --allow-empty
// OK-NOT: error
struct <T> NS { var v: T }
struct <> NS<bool> { var b: u8 }

extend <T> NS {
    fn get(self) -> T = self.v
}
extend <> NS<bool> {
    fn get(self) -> bool = self.b != 0x00
}
