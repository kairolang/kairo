union Register {
    var as_u32: u32
    var as_bytes: [u8; 4]
    var as_f32: f32
}

fn main() -> i32 {
    var r: Register
    r.as_u32 = 0x3F800000
    return r.as_bytes[0] + r.as_bytes[3]
}