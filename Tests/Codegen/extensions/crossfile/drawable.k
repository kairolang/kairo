// crossfile/drawable.k
import point::Point;

pub interface Drawable {
    fn draw(const self) -> i32
}

extend Point impl Drawable {
    pub fn draw(const self) -> i32 { return self.x * 10 + self.y; }
}
