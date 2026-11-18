// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty
//
// `map<string, Ext>` fills in <map>'s header set, which must lay out Ext,
// whose `set<string>` field only ext.k's <set> set can spell. The stand-in
// failed, the map never filled, and `begin` / `end` from its pattern tied
// (SC064E, ~97 self-host sites). A template another set owns is re-found
// here by name when visible; otherwise the field is a blob of its size and
// alignment, measured where it is spelled.
// CHECK-NOT: error

import ext::*
ffi "c++" import "map"

class H {
    var m: cxx::std::map<string, Ext>
    fn count(self) -> usize {
        var n: usize = 0
        for kv in self.m { n += kv.second.s.size() }
        return n
    }
}
