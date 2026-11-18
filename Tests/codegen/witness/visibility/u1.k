import iface
import ea
import eb
import metric::Metric
pub fn use_1() -> i32 {
    var m = Metric { base: 1 }
    return iface::both(m)
}
