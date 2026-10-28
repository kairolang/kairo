import iface
import metric::Metric
extend Metric impl iface::Named {
    pub fn tag(const self) -> i32 = self.base + 7
}
