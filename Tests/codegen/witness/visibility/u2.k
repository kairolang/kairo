import iface
import eb
import ea
import c3
import metric::Metric
pub fn use_2() -> i32 {
    var m = Metric { base: 2 }
    return iface::both(m) + c3::c3()
}
