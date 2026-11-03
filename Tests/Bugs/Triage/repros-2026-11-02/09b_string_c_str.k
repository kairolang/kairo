// Library gap: string has no c_str() (declared, not defined).
// Tests/Codegen/strings/c_str.k calls .c_str() on a var initialized from a
// literal; a `string` parameter has none. Expected: exit 2.
// Actual: R025E "no member named 'c_str' in 'string'". as_ptr() exists but
// returns *const u8, which does not pass to a `const char*` C parameter.
ffi "c" import "string.h"

fn clen(s: string) -> usize { return strlen(s.c_str()) }

fn main() -> i32 { return clen("ab") as i32 }
