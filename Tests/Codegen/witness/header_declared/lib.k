pub interface Scalable {
    fn scale(const self, factor: i32) -> i32
}
// Declared through the extension that meets it.
pub struct Metric {
    pub var base: i32
}
extend Metric impl Scalable {
    pub fn scale(const self, factor: i32) -> i32 = self.base * factor
}
// Declared on the class, met by a plain extension.
pub class Gauge impl Scalable {
    pub var g: i32 = 7
    fn Gauge(self) { }
}
extend Gauge {
    pub fn scale(const self, factor: i32) -> i32 = self.g + factor
}
// Declared, and met by an exact own member: the primary serves it.
pub class Own impl Scalable {
    pub var o: i32 = 1
    fn Own(self) { }
    pub fn scale(const self, factor: i32) -> i32 = self.o + factor
}
pub fn <T impl Scalable> twice(a: T) -> i32 {
    return a.scale(2)
}
