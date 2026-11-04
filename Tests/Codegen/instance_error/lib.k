pub class Cfg {
    pub var n: i32 = 7
    pub var xs: [i32; 3] = [1, 2, 3]
}

pub fn broken() -> i32 {
    var p = &null
    return 0
}
