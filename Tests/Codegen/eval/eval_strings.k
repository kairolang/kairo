// EVAL.md 2a: a string literal is eval-able. Where C++ reads one at compile
// time -- an eval binding, an eval fn's body, an argument of an eval call
// made from run-time code, an eval class's field -- its bytes are
// `__kairo_estr<...>`, a `const unsigned char` array keyed on them, and the
// literal constructor is `constexpr`: no `reinterpret_cast`, which no
// constant expression may hold. A run-time literal keeps the cast.

eval NAME = "Kairo"
eval EMPTY: string = ""

eval fn greet() -> string { return "hi!" }
eval fn width(s: string) -> usize { return s.len }
eval GREETING = greet()

pub class Config {
    pub var label: string
    pub var size: i32
    eval fn Config(self, label: string, size: i32) {
        self.label = label
        self.size = size
    }
}
eval CFG = Config("cfg", 4)

fn main() -> i32 {
    var g = greet()                      // an immediate invocation
    var w = width("abcd")                // its argument is read at compile time
    var plain = "run"                    // a run-time literal: unchanged
    var r = NAME.len + EMPTY.len + GREETING.len + g.len + w + plain.len + CFG.label.len
    if NAME.data[0] == 75 { r += 1 }     // 'K'
    if EMPTY.data[0] == 0 { r += 1 }     // the NUL the array carries
    return r as i32 + CFG.size           // 5 + 0 + 3 + 3 + 4 + 3 + 3 + 2 + 4 == 27
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR-LABEL: CODEGEN C++: {{.*}}eval_strings.k
// IR:      template<unsigned char ... C> inline constexpr unsigned char __kairo_estr[sizeof ...(C) + 1] =
// IR:      constexpr string(const unsigned char * data, decltype(sizeof(0)) len, decltype(sizeof(0)) cp_len) noexcept;
// IR:      inline constexpr string::string(const unsigned char * data,
// IR:      return::builtin::string::string( ::__kairo_estr<104, 105, 33>, 3, 3);
// IR:      inline constexpr::builtin::string::string const NAME = ::builtin::string::string( ::__kairo_estr<75, 97, 105, 114, 111>, 5, 5);
// IR:      inline constexpr::builtin::string::string const EMPTY = ::builtin::string::string( ::__kairo_estr<>, 0, 0);
// IR:      inline constexpr::eval_strings::Config const CFG = ::eval_strings::Config( ::builtin::string::string( ::__kairo_estr<99, 102, 103>, 3, 3), 4);
// IR:      ::eval_strings::width( ::builtin::string::string( ::__kairo_estr<97, 98, 99, 100>, 4, 4));
// IR:      ::builtin::string::string(reinterpret_cast<const unsigned char *>("run"), 3, 3);

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 27
