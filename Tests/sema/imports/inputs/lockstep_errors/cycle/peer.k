// Imports err.k back, which closes the cycle err.k -> peer.k -> err.k.
import err::*

pub fn base_offset() -> i32 { return 1 }

pub fn peer_reading() -> i32 {
    var m = Meter()
    return reading_of(m)
}
