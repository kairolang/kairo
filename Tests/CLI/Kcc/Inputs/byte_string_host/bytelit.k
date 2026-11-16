// bytelit.k: the Kairo side of bytes_main.cpp. A byte string is a `[const u8;]`,
// which a C++ host sees as a ::builtin::containers::slice::Slice<const unsigned char>:
// the address of the literal's static bytes and their count.

pub fn magic() -> [const u8;] {
    return b"\x7fELF\x00\xff"
}

pub fn total(xs: [const u8;]) -> u32 {
    var t: u32 = 0
    for var i: usize = 0; i < xs.len; ++i {
        t += xs[i]
    }

    return t
}
