# Conditionals
- if
- else
- unless
- else if
- else unless

---

## Table of Contents
- [Conditionals](#conditionals)
  - [Table of Contents](#table-of-contents)
    - [Scoped](#scoped)
    - [One Liner](#one-liner)
    - [Ternary](#ternary)
  - [Examples](#examples)

---

### Scoped
```rs
if a == b {...}
else if a == c {...}
else unless {...}
else {...}
```

### One Liner
```rs
if x < y: ...;
else if x > y: ...;
else unless: ...;
else: ...;
```

### Ternary
```rs
... if a == b else ...;
... unless a == b else ...;
```

---

## Examples
```rs
#[no_entry]

let a: i8 = 1;
let b: i8 = 2;

if a == b {
    print("a is equal to b");
} else if a == 1 {
    print("a is equal to 1");
} else unless a == 2 {
    print("a is not equal to 2");
} else {
    print("a is not equal to b");
}
```