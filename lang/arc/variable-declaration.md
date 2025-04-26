# Variable Declaration
- let
- priv
- const
- auto
- ? (nullable)
- & (reference)
- ptr

---

## Table of Contents
- [Variable Declaration](#variable-declaration)
  - [Table of Contents](#table-of-contents)
    - [Let](#let)
    - [Private](#private)
    - [Const](#const)
    - [Auto](#auto)
    - [Nullable](#nullable)
    - [Reference](#reference)
    - [Pointer](#pointer)
  - [Examples](#examples)
    
---

### Let
```rs
let a: int = 5;
let b: float = 5.5;
let c: int | float; // during first assignment, c can be either int or float
```

### Private
```rs
let priv b: int = 5;     // private variable
priv fn some_function(); // private function
```

### Const
```rs
const PI: float = 3.14159;
const fn some_function(&a: int); // a function that doesn't change the reference
```

### Auto
```cpp
auto c = 5; // inferred as int and not a sized type (i32, u64, etc)
auto f = "Hello, World!"; // inferred as a string
```

### Nullable
```rs
let a: int? = 5; // a can be either an int or null
let b: int? = null; // b is null

let a: int?; // a is null rather then the default constructor for int
```

### Reference
```rs
let a: int = 5;
let b: &int = &a; // b is a reference to a
let c: &int = &5; // error: cannot reference a temporary value
```

### Pointer
```rs
let a: int = 5;
let b: ptr<int> = &a; // b is a pointer to a

let c: ptr<int> = &5; // error: cannot point to a temporary value
```

---

## Examples
```rs
#[no_entry]

let a: int = 5;
let b: float = 5.5;
let c: int | float; // during first assignment, c can be either int or float

c = 5; // from now on, c can only be an int

struct Foo {
    let priv a: int;
    let priv b: float;

    fn new(a: int, b: float) -> Foo {
        return Foo(a, b);
    }

    fn get_a(&self) -> int {
        return self.a;
    }

    fn get_b(&self) -> float {
        return self.b;
    }
}

let foo = Foo(5, 5.5);

print(foo.get_a()); // 5
print(foo.b);       // error: b is private
```
