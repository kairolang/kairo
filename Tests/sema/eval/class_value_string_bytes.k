// A string literal in an `eval` class value argument is its decoded bytes:
// escapes are decoded (`\t`, `\xHH`, `\uHHHH`, octal, `\\`), a raw literal
// is copied as written, and the parts of an adjacent-literal chain are
// joined, each decoded by its own prefix. The spelled types below show the
// bytes; two arguments with the same bytes are one type (line 20 converts).
//
// `Config` holds a `string`, which is not a structural type today, so the
// declaration of `Widget` is refused as well; this test reads only the
// argument values.

pub struct Config {
    pub var size: i32
    pub var label: string
    eval fn Config(self, size: i32, label: string) {
        self.size = size
        self.label = label
    }
}

class <eval C: Config> Widget {
    fn Widget(self) { }
}

fn main() -> i32 {
    var a = Widget<Config(1, "a\tb\x41é\101\\")>()
    var b: Widget<Config(1, "zz")> = a
    var c = Widget<Config(2, r"c\n")>()
    var d: Widget<Config(2, "c\n")> = c
    var e = Widget<Config(3, "one" "\x42two" r"\three")>()
    var f: Widget<Config(3, "oneBtwo\\three")> = e
    var g: Widget<Config(3, "oneBtwo")> = e
    return 0
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: {{.*}}:26:38: error [SC028E]: cannot convert 'Widget<Config(1, "a\x09bA\xc3\xa9A\x5c")>' to 'Widget<Config(1, "zz")>'
// CHECK-NEXT: {{.*}}:28:39: error [SC028E]: cannot convert 'Widget<Config(2, "c\x5cn")>' to 'Widget<Config(2, "c\x0a")>'
// CHECK-NEXT: {{.*}}:31:43: error [SC028E]: cannot convert 'Widget<Config(3, "oneBtwo\x5cthree")>' to 'Widget<Config(3, "oneBtwo")>'
