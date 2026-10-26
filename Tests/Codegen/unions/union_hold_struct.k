// Tests/Codegen/unions/union_hold_struct.k
// build: kairo union_holds_struct.k   (expect exit 0)
// The reverse edge: the union holds a struct declared after it by value, and
// a struct holds that union by value. Little-endian layout assumed.
struct HardwareRegister {
    var address: usize
    var value: RegValue
}

union RegValue {
    var raw: u32
    var fields: RegFields
}

struct RegFields {
    var low: u16
    var high: u16
}

fn main() -> i32 {
    var reg: HardwareRegister
    reg.address = 0x4000_0000
    reg.value.raw = 0xDEAD_BEEF
    if (reg.value.fields.low == 0xBEEF) && (reg.value.fields.high == 0xDEAD) { return 0 }
    return 1
}