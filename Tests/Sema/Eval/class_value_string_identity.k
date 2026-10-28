pub struct Config {
    pub var size: i32
    pub var label: string
    eval fn Config(self, size: i32, label: string) {
        self.size = size
        self.label = label
    }
}

eval SMALL = Config(4, "small")

class <eval C: Config> Widget {
    fn Widget(self) { }
}

fn main() -> i32 {
    var a = Widget<Config(4, "small")>()
    var b: Widget<SMALL> = a
    var c: Widget<Config(4, "large")> = a
    var d: Widget<Config(5, "small")> = b
    return 0
}

// EVAL.md 7e / §11: a string literal in an eval class value argument is a
// value whose identity is its bytes. `Config(4, "small")` is SMALL (lines
// 17-18 accept); a different string or a different field is a different
// argument and so a different type.
// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: class_value_string_identity.k:19:41: error [SC028E]: cannot convert 'Widget<Config(4, "small")>' to 'Widget<Config(4, "large")>'
// CHECK: class_value_string_identity.k:20:41: error [SC028E]: cannot convert 'Widget<Config(4, "small")>' to 'Widget<Config(5, "small")>'
