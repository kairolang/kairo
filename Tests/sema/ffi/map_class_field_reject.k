// A class field of type cxx::std::map<K, V> is typed with its key and value
// types: a key or value of the wrong type is a Kairo type error, and a field
// that is never used reports nothing.

ffi "c++" import "map"

class Unused {
    pub var m: cxx::std::map<i32, i32>
}

class Holder {
    pub var m: cxx::std::map<i32, i32>
    fn put(self, k: i32, v: i32) { self.m[k] = v }
    fn bad(self) {
        var s: string = self.m[1]
        self.m["a"] = 1
    }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="CL001E"
// CHECK: map_class_field_reject.k:15:25: error [SC028E]: cannot convert 'i32&' to 'string'
// CHECK: map_class_field_reject.k:16:9: error [SC063E]: no matching overload for call to 'op []'
