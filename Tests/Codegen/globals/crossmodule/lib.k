pub const LIMIT: i32 = 40
pub var hits: i32 = 0

pub fn hit() -> i32 {
    hits = hits + 1
    return hits
}
