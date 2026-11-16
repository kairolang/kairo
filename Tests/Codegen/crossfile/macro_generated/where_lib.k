macro grades!(N_) {
    pub fn N_(x: i32) -> i32 where x >= 90 { return 4 }
    pub fn N_(x: i32) -> i32 where x >= 80 { return 3 }
    pub fn N_(x: i32) -> i32 { return 0 }
}

grades!(grade)
