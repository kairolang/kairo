# Async
- async
- spawn
- thread
- await

---

## Table of Contents
- [Async](#async)
  - [Table of Contents](#table-of-contents)
    - [async](#async-1)
    - [spawn](#spawn)
    - [thread](#thread)
    - [await](#await)
  - [Examples](#examples)

---

### async
```rs
async fn some_complex_function(a: i8) -> i8 {
    std::sleep(1000); // stimulate a long process
    return a;
}
```

### spawn
```rs
import  std::future::Future;

let a: Future = spawn  some_process(5); // spawns as a child process
```

### thread
```rs
import  std::future::Future;

let b: Future = thread some_process(5); // runs on a separate cpu thread
```

### await
```rs
let result = await a; // waits for the future to complete
let result = await b; // waits for the future to complete
```

---

## Examples
```rs
#[no_entry]
import std::future::Future;

async fn some_complex_function(a: i8) -> i8 {
    std::sleep(1000); // stimulate a long process
    return a;
}

let a: Future = spawn  some_process(5); // spawns as a child process
let b: Future = thread some_process(5); // runs on a separate cpu thread

print(await a); // waits for the future to complete
print(await b); // waits for the future to complete
```

```rs
#[no_entry]
import std::future::Future;

async fn some_complex_function(a: i8) -> i8 {
    std::sleep(1000); // stimulate a long process
    return a;
}

let a: Future = spawn  some_process(5); // spawns as a child process
let b: Future = thread some_process(5); // runs on a separate cpu thread

print(a.await); // waits for the future to complete
print(b.await); // waits for the future to complete
```

```rs
#[no_entry]
import std::future::Future;

async fn some_complex_function(a: i8) -> i8 {
    std::sleep(1000); // stimulate a long process
    return a;
}

let a: Future = spawn  some_process(5); // spawns as a child process
let b: Future = thread some_process(5); // runs on a separate cpu thread

print(a.await()); // waits for the future to complete
print(b.await()); // waits for the future to complete
```