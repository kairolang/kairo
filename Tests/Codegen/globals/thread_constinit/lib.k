pub thread hits: i32 = 0
pub thread const LIMIT: i32 = 40
pub thread seeded: i32 = seed()

fn seed() -> i32 { return 2 }

pub fn hit() -> i32 {
    hits += 1
    return hits
}
