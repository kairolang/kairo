// Corpus for CLI/Kcc/kcc_visibility.k: one function per visibility.
pub fn open_fn() -> i32 { return 1 }
prot fn mod_fn() -> i32 { return 2 }
priv fn file_fn() -> i32 { return 4 }
fn bare_fn() -> i32 { return 8 }
