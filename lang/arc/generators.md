# generators
- yield

---

## Table of Contents
- [generators](#generators)
  - [Table of Contents](#table-of-contents)
    - [Using Yield](#using-yield)
  - [Examples](#examples)
    
---

### Using Yield
```rs
fn fibonacci() {
    let a = 0;
    let b = 1;

    while true {
        yield a;
        let temp = a;
        a = b;
        b = temp + b;
    }
}
```

---

## Examples
```rs
#[no_entry]

fn fibonacci() {
    let a = 0;
    let b = 1;

    while true {
        yield a;
        let temp = a;
        a = b;
        b = temp + b;
    }
}

for i in fibonacci() {
    print(i);
    if i > 100 {
        break;
    }
}

// alternative syntax
let fib = fibonacci();

print(fib.next());
print(fib.next());
print(fib.next());
...
```