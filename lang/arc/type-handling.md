# Type Handling
- type_of!
- sizeof!
- is
- as
<!-- TODO: is_base for base classes -->
---

## Table of Contents
- [Type Handling](#type-handling)
  - [Table of Contents](#table-of-contents)
    - [type\_of!](#type_of)
    - [sizeof!](#sizeof)
    - [is](#is)
    - [as](#as)
  - [Examples](#examples)
    
---

### type_of!
```rs
print(type_of!(5)); // int
let some_var: type_of!(other_var) = 5; // other_var is an int
```

### sizeof!
```rs
print(sizeof!(int)); // 16
let a: int = 1 << 32; // as int is a var int
print(a.size()); // 4 bytes
```

### is
```rs
if a is int {
    print("a is an int");
}
```

### as
```rs
let a: int = 5;
let b: float = a as float; // 5.0
```

---

## Examples
```rs
let a: float = 5;

// a macro has a view of the ast namespace so this is valid, a would have to be defined
type BType = type_of!(a); // stores the type, error out and suggest the type alias keyword to stop chaining

let b: type_of!(a) = 5.0; // 5.0 as int (allowed since theres no chaining)

// ====-----sizeof -----==== //
let size = sizeof!(int); // 16 (size of ptr to heap and ptr to size)

let a: int = 2**32; // as int is a var int
print(a.size()); // 4 bytes

// ====-----is -----==== //
if a is int {
    print("a is an int");
}
```
