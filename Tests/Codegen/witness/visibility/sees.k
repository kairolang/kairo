import iface
import ea
import metric::Metric
pub fn use_a() -> i32 {
    var m = Metric { base: 3 }
    return iface::twice(m)
}
