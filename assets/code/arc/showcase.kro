class Point {
    var x: int;
    var y: int;

    eval fn Point(self, x: int, y: int) {
        self.x = x;
        self.y = y;
    }

    fn move(self, dx: int, dy: int) {
        self.x += dx;
        self.y += dy;
    }

    fn display(self) {
        print(f"Point at ({self.x}, {self.y})");
    }
}

fn main() {
    var p = Point(0, 0);

    for i in 1..4 {
        p.move(i, i);
        p.display();
    }

    var value: u32 = p.x as u32;

    match value {
        0 -> print("The point is at the origin"),
        1 | 2 | 3 -> print("The point is close to the origin"),
        _ -> print("The point is far from the origin"),
    }
}