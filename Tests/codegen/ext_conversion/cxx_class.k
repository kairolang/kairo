// An imported C++ class takes an `op as` from an extension like any other
// type, in both directions: `std::string` to Kairo types, and a Kairo
// `string` to `std::string`, which a C++ parameter then takes with no cast.

ffi "c++" import "string"

struct Len { var n: i32 }

extend cxx::std::string {
    @implicit fn op as (const self) -> Len { return Len{n: self.size() as i32} }

    fn op as (const self) -> string {
        var out = string()
        for var i: usize = 0; i < self.size(); ++i {
            out.push((self.at(i) as u8) as char)
        }

        return out
    }
}

extend string {
    @implicit fn op as (const self) -> cxx::std::string {
        return cxx::std::string(unsafe (self.data() as unsafe *const __builtin_c_char), self.size())
    }
}

fn take(l: Len) -> i32 { return l.n }
fn takes(const s: cxx::std::string) -> i32 { return s.size() as i32 }

fn main() -> i32 {
    var c = cxx::std::string("abcd")
    var k: string = "xyz"
    var back = c as string
    return take(c) + takes(k) + (back.size() as i32) - 11
}

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe
