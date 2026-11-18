// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty
//
// `unordered_map<string, unsafe *Node>` is filled in <unordered_map>'s
// header set, which needs a stand-in for Node there. Node points at Ext,
// and Ext holds a `cxx::std::set<string>` from ANOTHER set (ext.k's), which
// this one cannot spell, so the stand-in, the fill and the map's members
// all fail: `op []` would come from the unfilled pattern, its result stay
// dependent, and `self.children[name]` be an internal error ("SubscriptExpr
// reached finish() in no terminal state").
// A pointer field only needs a pointer's layout.
// CHECK-NOT: error
// CHECK-NOT: Internal Compiler Error

import ext::*
ffi "c++" import "unordered_map"

pub class Node {
    pub var children: cxx::std::unordered_map<string, unsafe *Node>
    pub var ext: unsafe *Ext

    fn get(self, name: string) -> unsafe *Node {
        return self.children[name]
    }
}
