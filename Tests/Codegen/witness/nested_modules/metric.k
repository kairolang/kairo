pub struct Metric {
    pub var base: i32
}
extend Metric {
    pub fn scale(const self, factor: i32) -> i32 = self.base * factor
}
