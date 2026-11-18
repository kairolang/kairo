// build: kairo f16_payload_enum_ignores_declared_tag_type.k -o f27   (expect exit 2: a u8 tag, then a u8 payload)
enum Small derives u8 { A { r: u8 }, B }    // accepted; the `u8` is ignored

fn main() -> i32 {
    return sizeof(Small) as i32             // 8 today: the tag is u32
}
