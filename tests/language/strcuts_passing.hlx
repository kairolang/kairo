struct Point {
    var x: i32;
    var y: i32;

    fn op + (self, other: &Point) -> Point {
        return Point {
            x = self.x + other.x,
            y = self.y + other.y
        };
    }
}

struct Foam {
    var x: i32;

    fn op + (self) -> i32 { // works
        return self.x;
    }
}

struct Soap {
    var x: i32;

    enum {
        A,
        B,
        C
    } // works
}

struct Lick {
    var x: i32;
    const y: i32 = 10;
}

struct Pick {
    var x: i32;
    enum EnumName {
        A,
        B,
        C
    }

    const y: EnumName = EnumName::A;
}

struct Arugula {
    var x: i32;
    var y: i32;
    var z: i32;
    var w: i32;
    var v: i32;
    var u: i32;
    var t: i32;
    var s: i32;
    var r: i32;
    var q: i32;
    var p: i32;
    var o: i32;
    var n: i32;
    var m: i32;
    var l: i32;
    var k: i32;
    var j: i32;
    var i: i32;
    var h: i32;
    var g: i32;
    var f: i32;
    var e: i32;
    var d: i32;
    var c: i32;
    var b: i32;
    var a: i32;
}

struct Sitting1 {
    struct Nested {
        var x: i32;
    }

    var woa: Nested;
}

struct Sitting2 {
    struct Nested {
        var x: i32;
    }

    var woa: Nested;
    var x: i32;
}

struct Sitting3 {
    type alias_to_int = i32;
    var x: alias_to_int;
}

fn main() -> i32 {
    var p = Point { x = 3, y = 4 };
    print(f"({p.x}, {p.y})");

    var q: Point;
    q = Point { x = 1, y = 2 };
    
    var r: Point = p + q;

    print(f"({r.x}, {r.y})");

    return 0;
}

/*
--------- do not remove this comment, it is used by the test script to validate the output ---------
// START TEST
(3, 4)
(4, 6)
// END TEST
*/