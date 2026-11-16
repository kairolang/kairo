// A class that is only forward-declared does not count as declared:
// `<iosfwd>` names `std::string` and `std::vector` without defining them,
// and nothing can be done with either name but point at it. An extension
// conditional on `cxx::std::string` therefore does not exist in a build
// whose headers stop at `<iosfwd>`, and its body, which constructs one, is
// never checked. The same holds for a Kairo forward declaration.

ffi "c++" import "iosfwd"

struct Later
struct Now { var v: i32 }

extend string requires __builtin_is_declared<cxx::std::string>() {
    pub fn to_cxx(const self) -> cxx::std::string {
        return cxx::std::string(self.c_str(), self.size())
    }
}

eval STRING  = __builtin_is_declared<cxx::std::string>()
eval VECTOR  = __builtin_is_declared<cxx::std::vector>()
eval STREAM  = __builtin_is_declared<cxx::std::ostream>()
eval LATER   = __builtin_is_declared<Later>()
eval NOW     = __builtin_is_declared<Now>()

fn main() -> i32 {
    var t = 0
    if STRING || VECTOR || STREAM || LATER { t += 100 }
    if NOW { t += 1 }
    return t - 1
}

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe
