union Payload    // forward declaration

struct Message {
    var kind: u8
    var data: unsafe *Payload
}

union Payload {
    var as_int: i64
    var as_bytes: [u8; 8]
}