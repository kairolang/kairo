# Data Structures
- class
- struct
- enum
- union
- interface  ~ *concepts*
- abstract   ~ virtual and default methods and concepts
- type

---

## Table of Contents
- [Data Structures](#data-structures)
  - [Table of Contents](#table-of-contents)
    - [Class](#class)
    - [Struct](#struct)
    - [Enum](#enum)
    - [Union](#union)
    - [Interface](#interface)
    - [Abstract](#abstract)
    - [Type](#type)
  - [Examples](#examples)
    
---

### Class
```rs
class Point3D derives Point { // makes all methods and fields of Point available
    let z: int;

    fn new(x: int, y: int, z: int) {
        super(x, y); // calls the constructor of the parent class
        self.z = z;
    }

    fn delete() {
        // destructor
    }

    fn move(x: int, y: int, z: int) {
        self.x += x;
        self.y += y;
        self.z += z;
    }
}

class Vector impl VectorInterface { // implements VectorInterface
    let priv x: int;
    let priv y: int;

    fn new(x1: int, y1: int) -> Vector{
        return Vector {
            x: x1,
            y: y1
        };
    }
    // TODO: make this look better
    fn delete() {
        // destructor
    }

    fn add(a: Vector, b: Vector) -> Vector {
        return Vector::new(a.x + b.x, a.y + b.y);
    }
}
```

### Struct
```rs
struct Point {
    let x: int;
    let y: int;

    fn new(x: int, y: int) -> Point {
        return Point { x, y };
    }
}

let point: Point = Point::new(0, 0);
```

### Enum
```cpp
enum RGBColor {
    Red;
    Green;
    Blue;
}
```

### Union
```rs
union Number {
    some_int:    int;
    some_float:  float;
    some_double: decimal;
}
```

### Interface
```cs
// interfaces are the only data structure that can be used as generic bounds
interface Drawable {
    fn draw();
    fn erase();
}
```

### Abstract
```rs
abstract Shape : Drawable {
    fn erase(); // must be implemented

    fn draw() { // can be overridden
        print("Drawing Shape");
    }
}
```

### Type
```rs
type Point = (int, int);
type DrawableObject<T: Drawable>; // allows any type that implements Drawable
let some_shape: DrawableObject<Shape> = Shape::new(); // Shape implements Drawable
```

---

## Examples
```rs
#[no_entry]

class Point {
    let x: int;
    let y: int;

    fn new(x: int, y: int) {
        self.x = x;
        self.y = y;
    }
}

class Point3D derives Point {
    let z: int;

    fn new(x: int, y: int, z: int) {
        super(x, y);
        self.z = z;
    }

    fn delete() {
        // destructor
    }

    fn move(x: int, y: int, z: int) {
        self.x += x;
        self.y += y;
        self.z += z;
    }
}

struct Vector {
    let x: int;
    let y: int;

    fn new(x: int, y: int) {
        self.x = x;
        self.y = y;
    }
}

enum RGBColor {
    Red;
    Green;
    Blue;
}

union Number {
    some_int:    int;
    some_float:  float;
    some_double: decimal;
}

interface Drawable {
    fn draw();
    fn erase();
}

abstract Shape derives Drawable {
    fn erase();

    fn draw() {
        print("Drawing Shape");
    }
}

type DrawableObject<T: Drawable>; // make a custom type
let some_shape: DrawableObject<Shape> = new Shape();
// Shape implements all methods of Drawable, Shape does NOT have to implement Drawable explicitly

// or

let other_shape: Drawable = new Shape(); // Shape MUST implement Drawable explicitly
```
