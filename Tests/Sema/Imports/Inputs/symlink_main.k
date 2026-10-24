// Reaches the library through b/geolink, a symlink to it
// (module_pins_symlink.k).
import geo::shapes

fn use_area() -> i32 { return shapes::area() }
