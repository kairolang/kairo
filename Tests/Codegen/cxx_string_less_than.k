// O45: `<` between two cxx::std::strings is operator< (a bool), not a
// three-way compare cast to a narrow integer.
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe

ffi "c++" import "string";
ffi "c++" import "vector";
ffi "c++" import "algorithm";
fn main() -> i32 {
    var v = cxx::std::vector<cxx::std::string>();
    v.push_back(cxx::std::string("b"));
    v.push_back(cxx::std::string("a"));
    cxx::std::sort(v.begin(), v.end(),
        fn (const a: cxx::std::string, const b: cxx::std::string) || -> bool = a < b);
    if v[0] == cxx::std::string("a") { return 0; }
    return 1;
}
