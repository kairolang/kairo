import module::shared
import module::deep::peer as p

pub fn total() -> i32 { return shared::shared_value() + p::peer_value(); }
