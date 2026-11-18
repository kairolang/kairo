// A file-scope `eval { }` block holds compile-time declarations only and
// emits nothing, empty or not.
eval {
}

eval {
    fn twice(x: i32) -> i32 { return x * 2 }
}

fn main() -> i32 { return 0 }

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: rm -f %t.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
