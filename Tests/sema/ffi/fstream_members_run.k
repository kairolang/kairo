// The members of the file streams type concretely (`tellp`, `tellg`,
// `gcount`, `seekg`, `read`, `write`, `rdbuf`), and a program that writes
// a file through an `ofstream` and reads it back through an `ifstream`
// builds and runs: no member is left an untyped specialization. Exit 0
// when `gcount` reports the 5 bytes read.

ffi "c++" import "fstream"
ffi "c++" import "string"

fn main() -> i32 {
    var path = "/tmp/kairo_fstream_members_run.txt"
    var s = cxx::std::to_string(12345 as i32)
    {
        var out: cxx::std::ofstream
        out.open(path.c_str())
        out.write(s.c_str(), 5)
        var p = out.tellp()
        out.close()
    }
    var inp: cxx::std::ifstream
    inp.open(path.c_str())
    var buf: cxx::std::string
    buf.resize(5)
    inp.read(unsafe buf.data(), 5)
    var n = inp.gcount()
    var t = inp.tellg()
    inp.seekg(t)
    var unsafe *rb = inp.rdbuf()
    inp.close()
    if n == 5 { return 0 }
    return 1
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error
// DIAG-NOT: warning
// REQUIRES: clang
// RUN: rm -rf %t.d %t.exe
// RUN: %kairo %s -O0 -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 0
