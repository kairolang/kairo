// build: kairo F26-union-codegen-ice.k   (expect exit 254)
union Color {
    var rgba: u32
    var channels: [u8; 4]
}

fn main() -> i32 {
    var c: Color
    c.rgba = 0xFF0000FF
    return c.channels[0] + c.channels[3]
}
