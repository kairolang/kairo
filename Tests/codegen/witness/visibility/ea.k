import iface
import metric::Metric
extend Metric impl iface::Scalable {
    pub fn scale(const self, factor: i32) -> i32 = self.base * factor
}
