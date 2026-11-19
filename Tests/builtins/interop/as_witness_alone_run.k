// `as` from a map or set of primitives, with nothing else in the unit that
// copies a primitive through `Copyable`: the conversion compiles and runs on
// its own, because the map's key copy states the `Copyable` bound it uses.

ffi "c++" import "unordered_map"
ffi "c++" import "unordered_set"

fn main() -> i32 {
    var m = HashMap<u64, u64>()
    m.insert(1, 2)
    var s = HashSet<u64>()
    s.insert(3)
    var c = m as cxx::std::unordered_map<u64, u64>
    var d = s as cxx::std::unordered_set<u64>
    return (c.size() + d.size() - 2) as i32
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
