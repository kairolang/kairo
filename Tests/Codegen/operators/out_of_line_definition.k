// An operator defined out of line (`fn T::op [] (...) { ... }`): its name
// is its op_token, it has no name token, and NameResolution and
// RedeclMerge spelled that empty token to look the declaration up, which a
// debug compiler stopped on ("ImmediateTable is null in
// TokenText::resolve"). The lookup is by the operator's key; this pins that
// the definition attaches, links to its declaration, and runs.

class Late {
    var d: [i32; 3]
    fn Late(self) {
        self.d = [10, 20, 30]
    }

    fn op [] (self, i: usize) -> *i32
    fn op + (const self, k: i32) -> i32
}

fn Late::op [] (self, i: usize) -> *i32 {
    return &self.d[i]
}

fn Late::op + (const self, k: i32) -> i32 {
    return self.d[0] + k
}

fn main() -> i32 {
    var l = Late()
    l[1] = 7
    return l[1] + (l + 5) // 7 + 15
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=TC --allow-empty
// TC-NOT: {{error|Internal Compiler Error}}
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 22
