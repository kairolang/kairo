// A named function in a struct body is rejected - but it is still PARSED, so
// each bad member costs exactly one diagnostic and the fields around it keep
// parsing. Three bad members here, three errors, no cascade.
// RUN: { %kairo %s --syntax-only 2>&1 1>/dev/null || true; } | %FileCheck %s --check-prefix=ERR
// ERR: :11:5: error [S048E]: a struct or union body cannot contain a named function
// ERR: :13:5: error [S048E]: a struct or union body cannot contain a named function
// ERR: :14:5: error [S048E]: a struct or union body cannot contain a named function
// ERR-NOT: error [S
struct Point {
    var x: i32
    fn length(self) -> i32 { return self.x }
    var y: i32
    static fn origin() -> i32 { return 0 }
    inline fn scale(self, k: i32) -> i32 { return self.x * k }
    var z: i32
}
