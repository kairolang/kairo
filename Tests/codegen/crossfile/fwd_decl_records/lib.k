// Imported by main.k. Forward declarations and their definitions in this
// module; main.k names the records only through it, so the merged chain
// (and the C++ tags EmitPlan forward-declares for them) has to be the
// definition's from another TU too.

pub union Payload
pub struct Message {
    pub var kind: u8
    pub var data: unsafe *Payload
}
pub union Payload {
    pub var as_int: i64
    pub var as_bytes: [u8; 8]
}

pub struct Ring
pub struct Ring { pub var n: i32 }
