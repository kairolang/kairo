// Two specialization heads reach the post-name argument pattern:
//   `<>  Name<i32>`  full/explicit  - the marker carries no params
//   `<P> Name<*P>`   partial        - the param list binds the pattern vars
// Without the second, SpecKind::Partial is unreachable from the grammar.
// RUN: %kairo %s --syntax-only 2>&1 | %FileCheck %s --check-prefix=OK --allow-empty
// OK-NOT: error
struct <T> NS { var v: T }
struct <> NS<bool> { var b: u8 }
struct <P> NS<*P> { var p: unsafe P }

class <T> CS { var v: T }
class <P> CS<*P> { var p: unsafe P }

union <T> US { var v: T }
union <P> US<*P> { var p: unsafe P }
