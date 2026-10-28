import std::io::println

pub enum Color derives u8 {
    Red = 1,
    Green = 2,
    Blue = 4,
}

pub enum Shape { Circle { r: i32 }, Square { side: i32 }, Empty }

pub fn area(s: Shape) -> i32 {
    return match s {
        case .Circle(var r)    => 3 * r * r
        case .Square(var side) => side * side
        case .Empty            => 0
    }
}

pub fn make_square(n: i32) -> Shape {
    return .Square { side: n }
}

module inner {
    pub fn deep(x: i32) -> i32 { return x * 7; }
}

pub struct V2 {
    pub var x: i32 = 0;
    pub var y: i32 = 0;

    fn op +(self, o: V2) -> V2 { return V2{ x: self.x + o.x, y: self.y + o.y } }
}

extend V2 {
    pub fn dot(self, o: V2) -> i32 { return self.x * o.x + self.y * o.y; }
}

pub class Counter {
    pub static made: i32 = 0
    pub const id: i32
    pub var n: i32 = 0

    pub fn Counter(self, id: i32) {
        self.id = id;
        Counter::made += 1;
    }

    pub fn bump(self, @inout k: i32) -> i32 {
        k += 1;
        self.n += k;
        return self.n;
    }

    pub fn get(const self) -> i32 { return self.n; }
}

pub class Base {
    pub var b: i32 = 5
    @move pub fn Base(self, other: Self) = default
    pub fn Base(self) { }
    virtual fn who(self) -> i32 { return 1; }
    virtual fn op delete(self) { }
}

pub class Derived derives Base {
    @move pub fn Derived(self, other: Self) = default
    pub fn Derived(self) { }
    override fn who(self) -> i32 { return 2; }
    override fn op delete(self) { }
}

pub fn pair(a: i32) -> (i32, i32) {
    return (a, a * 2)
}

pub fn greet(name: string) -> string {
    return f"hi {name}"
}

pub fn shout(s: string) {
    println(s)
}
