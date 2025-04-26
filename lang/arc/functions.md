# Functions
- fn
- operator
- inline
- return

---

## Table of Contents
- [Functions](#functions)
  - [Table of Contents](#table-of-contents)
    - [Function Declaration](#function-declaration)
    - [Lambda Functions](#lambda-functions)
    - [Operator Overloading](#operator-overloading)
    - [Inline Functions](#inline-functions)
    - [Inline Lambda Functions](#inline-lambda-functions)
  - [Examples](#examples)

---

### Function Declaration
```rs
fn add(a: int, b: int) -> int {
    return a + b;
}
```

### Lambda Functions
```rs
let add: Fn<[int], (int, int)> = fn (a: int, b: int) -> int: a + b;
```

### Operator Overloading
```dart
class Vector {
    let x: int;
    let y: int;

    operator + is add(a: Vector, b: Vector) -> Vector {
        return Vector(a.x + b.x, a.y + b.y);
    }
}
```
### Inline Functions
```rs
inline fn add(a: int, b: int) -> int {
    return a + b;
}
```

### Inline Lambda Functions
```rs
let add: Fn<[int], (int, int)> = inline fn (a: int, b: int) -> int: a + b;
```

---

## Examples
```rs
#[no_entry]

fn add(a: int, b: int) -> int {
    return a + b;
}

fn add_one(a: int) -> int: a + 1;

class Vector {
    let x: int;
    let y: int;

    fn new(x: int, y: int) {
        self.x = x;
        self.y = y;
    }

    operator + as add(a: Vector, b: Vector) -> Vector {
        return Vector(a.x + b.x, a.y + b.y);
    }
}

let a: i8  = 1;
let b: i8  = 2;
let c: int = add(a, b);
let d: int = add_one(a);

let v1 = Vector(1, 2);
let v2 = Vector(3, 4);
let v3 = v1 + v2;

print(c); // 3
print(d); // 2
print(f"Vector({v3.x}, {v3.y})");  // Vector(4, 6)
```