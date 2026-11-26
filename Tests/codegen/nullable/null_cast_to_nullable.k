// `null as T?` is the null of the target nullable type (nullables.mdx,
// casting.mdx); it must neither ICE nor convert a value.

fn main() -> i32 {
    var a? = null as i64?
    var b: i32? = null as i32?
    var c = (null as i64?) ?? 7
    if a? || b? || c != 7 {
        return 1
    }

    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -f %t.exe
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
