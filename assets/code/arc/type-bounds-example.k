interface Drawable {
    fn draw();
    fn erase();
}

class Circle derives Drawable {
    var radius: float;

    fn Circle(self, radius: float) {
        self.radius = radius;
    }

    fn draw(self) {
        print(f"drawing Circle with radius: {self.radius}");
    }

    fn erase(self) {
        print("erasing Circle");
    }
}

class Square derives Drawable {
    var side: float;

    fn Square(self, side: float) {
        self.side = side;
    }

    fn draw(self) {
        print(f"drawing Square with side: {self.side}");
    }

    fn erase(self) {
        print("erasing Square");
    }
}

fn <T> draw_all(...objects: T)
  requires T impl Drawable {
    for obj in objects {
        obj.draw();
    }
}

fn main() {
    var shapes = (Circle(1.0), Square(1.0), Circle(2.0)); // type of tuple

    draw_all(shapes...);
}
