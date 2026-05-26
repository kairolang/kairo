// fn initialize_obj(a: int, b: int, obj: Point, x: int = 0, y: int = 0) {
//     // code
// }

pf: u + (-u) = 0

// implicit object creation - function defined above
initialize_obj(
    12,
    13,
    {
        .x = 10,
        .y = 20
    },
    x = 30,
    y = 40
);

struct Complex {
    a: int,
    b: int
}

struct PointObject {
    x: int,
    y: int,
    c: Complex
}

// explicit object creation with implicit object creation
 PointObject {
     x = 10,
     y = 20,
     c = {
        .a = 1,
        .b = 2
     }
 };