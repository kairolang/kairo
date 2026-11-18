// An element of a C++ vector whose argument is a record nested in a generic
// class (`self.ops[j].kind`) is the instance's: `vector<Op>` is
// instantiation-dependent, so the member step goes out as written and clang
// resolves it per instance instead of ICEing "unbound member step".

ffi "c++" import "vector";

enum K { A, B }

class <T> L {
    struct Op { var kind: K; var index: usize }
    priv var ops: cxx::std::vector<Self::Op>;
    fn add(self, k: K, i: usize) { self.ops.push_back(Self::Op{kind: k, index: i}); }
    fn count(self) -> usize {
        var n: usize = 0;
        for var j: usize = 0; j < self.ops.size(); j++ {
            if self.ops[j].kind == K::A && self.ops[j].index > 0 { n += 1; }
        }
        return n;
    }
}

fn main() -> i32 {
    var l: L<i32>;
    l.add(K::A, 1); l.add(K::B, 2); l.add(K::A, 3); l.add(K::A, 0);
    return l.count() as i32;   // 2
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 2
