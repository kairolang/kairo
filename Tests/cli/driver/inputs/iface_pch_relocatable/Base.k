// Tests/cli/driver/incremental_iface_pch_relocatable.k: imported by both
// entries and first by module path in Two.k's graph, so Callee.k is the
// first TU of neither interface PCH (the first one's key names the TUs the
// PCH's Sema agreement walk covered). It names no string.
pub fn base_n() -> i32 {
    return 5
}
