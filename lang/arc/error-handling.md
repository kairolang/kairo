# Error Handling
- try
- catch
- finally
- panic

---

## Table of Contents
- [Error handling](#error-handling)
  - [Table of Contents](#table-of-contents)
    - [Try-Catch](#try-catch)
    - [Single line try-catch](#single-line-try-catch)
    - [Try-Finally](#try-finally)
    - [Try-Catch-Finally](#try-catch-finally)
    - [Panic](#panic)
  - [Examples](#examples)
    
---

### Try-Catch
```cpp
try {
    let a = 5 / 0;
} catch e {
    print(e);
}
```

### Single line try-catch
```cpp
try: let a = 5 / 0;
catch e: print(e);
```

### Try-Finally
```cpp
try {
    let a = 5 / 0;
} finally {
    print("Finally");
}
```

### Try-Catch-Finally
```cpp
try {
    let a = 5 / 0;
} catch e {
    print(e);
} finally {
    print("Finally");
}
```

### Panic
```cpp
panic RuntimeError("An error occurred"); // panics with a RuntimeError
```

---

## Examples
```cpp
#[no_entry]

try: let a = 5 / 0;
catch DivisionByZero as e: let b = 5 / 0;
finally: print("it either worked or it didn't this will always run");

try {
    std::sleep(1000); // stimulate a long process
    panic RuntimeError("An error occurred");
} catch RuntimeError as e {
    print(f"RuntimeError ocurred: {e}");
} catch DivisionByZero as e {
    print(f"DivisionByZero ocurred: {e}");
} finally {
    print("cleaning up resources");
}
```
