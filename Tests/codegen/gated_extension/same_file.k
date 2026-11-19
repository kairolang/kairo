// Conditional extensions in the file that also has the headers: the
// clause holds here, so the members are usable in this very file. A clause
// may ask about several paths, mix the question with a test of a type
// parameter (`&& T impl Tag`), and stand in a module block. A block whose
// path names nothing (`cxx::std::no_such`) is an untaken branch: its
// signature is never resolved, so it is no error.

ffi "c++" import "string"
ffi "c++" import "vector"
interface Tag { fn tag(const self) -> i32 }
struct A { var v: i32 }
extend A impl Tag { fn tag(const self) -> i32 { return self.v } }
struct <T> Box { var v: T }

// the gate holds in this very file
extend string requires __builtin_is_declared<cxx::std::string>() {
    pub fn to_cxx(const self) -> cxx::std::string { return cxx::std::string(unsafe (self.data() as unsafe *const __builtin_c_char), self.size()) }
    @implicit pub fn op as (const self) -> cxx::std::string { return self.to_cxx() }
}
// mixed with a type-parameter test
extend <T> Box<T> requires __builtin_is_declared<cxx::std::vector>() && T impl Tag {
    pub fn tags(const self) -> cxx::std::vector<i32> {
        var out = cxx::std::vector<i32>()
        out.push_back(self.v.tag())
        return out
    }
}
module inner {
    extend i32 requires __builtin_is_declared<cxx::std::string>() && __builtin_is_declared<cxx::std::vector>() {
        pub fn twice(const self) -> i32 { return self * 2 }
    }
    extend i32 requires __builtin_is_declared<cxx::std::no_such>() {
        pub fn gone(const self) -> cxx::std::no_such { return 1 }
    }
}
fn takes(const s: cxx::std::string) -> i32 { return s.size() as i32 }
fn main() -> i32 {
    var s: string = "abcd"
    var b = Box<A>{v: A{v: 7}}
    var n: i32 = 5
    return takes(s) + (s.to_cxx().size() as i32) + (b.tags().size() as i32) + n.twice() - 19
}

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe
