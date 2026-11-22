// Tests/cli/driver/incremental_iface_pch_relocatable.k: a record holding a
// `@relocatable` string, taken by value.
pub struct Meta {
    pub var s: string
    pub var a: u64
    pub var b: u64
    pub var c: u64
}

@no_inline pub fn take(m: Meta) -> i32 {
    return (m.s.size() as u64 + m.a + m.b + m.c) as i32
}
