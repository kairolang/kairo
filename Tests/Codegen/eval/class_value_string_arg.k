// EVAL.md 7e / §11 (USER): a string literal written in an eval class value
// argument is a compile-time value whose identity is its decoded bytes,
// so `Widget<Config(4, "small")>` is `Widget<SMALL>` when SMALL is built
// by that same constructor call over the same literals: one Kairo type
// (assignable both ways) and one C++ specialization. C++ gets the string
// built over its bytes, `__kairo_estr<...>`, the same object wherever it is
// spelled, so the two class-type template arguments are equivalent there too.

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
    fn size(const self) -> i32 { return C.size }
    fn label_len(const self) -> usize { return C.label.len }
}

fn main() -> i32 {
    var a = Widget<Config(4, "small")>()
    var b: Widget<SMALL> = a                        // the same type
    var c: Widget<Config(4, "sm" "all")> = b        // the same bytes
    var d = Widget<Config(2, "é!")>()                 // multi-byte: 3 bytes, 2 codepoints
    // Past 256 bytes the bytes are one named array (EVAL.md §11).
    var l = Widget<Config(1, "abcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghij")>()
    return c.size() + (a.label_len() as i32) + d.size() + (d.label_len() as i32) + (l.label_len() as i32) - 290
        // 4 + 5 + 2 + 3 + 300 - 290 == 24
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR-LABEL: CODEGEN C++: {{.*}}class_value_string_arg.k
// IR:      inline constexpr unsigned char __kairo_estrh_300_{{[0-9a-f]+}}[301] =
// IR:      template< ::class_value_string_arg::Config C> class Widget {
// IR:      ::class_value_string_arg::Widget< ::class_value_string_arg::Config(4, ::builtin::string::string( ::__kairo_estr<115, 109, 97, 108, 108>, 5, 5))> a =
// IR:      ::class_value_string_arg::Widget< ::class_value_string_arg::Config(4, ::builtin::string::string( ::__kairo_estr<115, 109, 97, 108, 108>, 5, 5))> b = a;
// IR:      ::class_value_string_arg::Widget< ::class_value_string_arg::Config(2, ::builtin::string::string( ::__kairo_estr<195, 169, 33>, 3, 2))> d =
// IR:      ::class_value_string_arg::Widget< ::class_value_string_arg::Config(1, ::builtin::string::string( ::__kairo_estrh_300_{{[0-9a-f]+}}, 300, 300))> l =

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 24
