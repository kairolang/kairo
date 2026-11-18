import geo::render
import geo::text
import geo::vec

fn helper(l: text::Label) -> f64 {
    return render::place(l) + render::boxed(2.0).get()
}

fn main() -> i32 {
    var l = text::Label{ pos: vec::Vec2{ x: 3.0, y: 4.0 }, font: &null }
    return 7 + (helper(l) as i32)
}
