import c3
import iface
import metric::Metric
pub fn use_b() -> i32 {
    var m = Metric { base: 5 }
    return iface::twice(m) + c3::c3()
}
