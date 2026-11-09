// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 21
//
// A C++ container of a Kairo class that DERIVES (or of a member type
// of one). Filling `vector<X>` needs a C++ stand-in for X, and a stand-in
// was refused for any class with a base, so the instance stayed unfilled
// and its members came from the pattern, whose `size_type` is dependent:
// SC063E on `v[i]` / `reserve(4)`, SC066E on `i < v.size()`. The shapes
// are the self-host's: DiagEngine derives a class with virtual methods and
// holds `vector<PoisonEntry>` of its member struct; Decl derives two
// instances of generic mixins and is held as `vector<unsafe *Decl>`.

ffi "c++" import "vector";

class VBase {
    virtual fn emit(self, n: i32) -> i32 { return n }
    virtual fn op finally (self) { }
}

class <T> Mixin { var tag: u32 = 0 }
class <T> Mixin2 { var note: u64 = 0 }

class Engine derives VBase {
    struct Entry { var code: u32; var line: u32 }
    var entries: cxx::std::vector<Entry>
    var peers: cxx::std::vector<unsafe *Engine>
    fn Engine(self) { self.entries.reserve(4); self.peers.reserve(2) }
    fn sum(self) -> u32 {
        var t: u32 = 0
        for var i: usize = 0; i < self.entries.size(); ++i { t += self.entries[i].code }
        return t
    }
}

class Node derives Mixin<Node>, Mixin2<Node> { var k: i32 = 0 }

fn count(v: cxx::std::vector<unsafe *Node>) -> usize {
    var n: usize = 0
    for var i: usize = 0; i < v.size(); ++i { if v[i] != &null { n += 1 } }
    return n
}

fn main() -> i32 {
    var e = Engine()
    e.entries.push_back(Engine::Entry{code: 10, line: 1})
    e.entries.push_back(Engine::Entry{code: 9, line: 2})
    var a = Node()
    var v: cxx::std::vector<unsafe *Node>
    unsafe { v.push_back(&a as unsafe *Node) }
    v.push_back(&null)
    return (e.sum() as i32) + (count(v) as i32) + e.emit(1)
}

// DIAG-NOT: error
