# Macros
- assert!

---

## Table of Contents
- [Macros](#macros)
  - [Table of Contents](#table-of-contents)
    - [assert!](#assert)
  - [Examples](#examples)

---

### assert!
```rs
assert!(true); // does nothing

assert!(false); // panics with "Assertion failed"

assert!(false, "An error occurred"); // panics with Assertion failed: An error occurred
```

---

## Examples
```rs
let a: int = 5;
let b: int = 10;

assert!(a == b, "a and b are not equal"); // panics with "Assertion failed: a and b are not equal"
```
