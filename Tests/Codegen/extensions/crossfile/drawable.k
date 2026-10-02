// crossfile/drawable.k
import point::Point;
import shape

pub interface Drawable {
    fn draw(const self) -> i32
}

extend Point impl Drawable {
    pub fn draw(const self) -> i32 { return self.x * 10 + self.y; }
}

// A second `Point`, from another module, extended in the same namespace:
// neither target is declared here, so each scope takes its target's full
// path and the two never share a struct.
extend shape::Point impl Drawable {
    pub fn draw(const self) -> i32 { return self.a + self.b; }
}
