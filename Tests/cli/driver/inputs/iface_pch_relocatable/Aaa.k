// Tests/cli/driver/incremental_iface_pch_relocatable.k: the first module of
// One.k's graph by module path. Its stream defines string's out-of-line
// move constructor and does not name Callee::Meta.
pub fn aaa_len(s: string) -> usize {
    var t = s
    return t.size()
}
