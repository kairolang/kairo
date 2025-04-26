
# Module Imports
- import
- using
- from
- as

---

## Table of Contents
- [Module Imports](#module-imports)
  - [Table of Contents](#table-of-contents)
    - [Importing Helix Modules](#importing-helix-modules)
    - [Importing Rust](#importing-rust)
    - [Importing C++](#importing-c)
    - [Importing Python](#importing-python)
    - [Importing a single function](#importing-a-single-function)
  - [Examples](#examples)
    
---

### Importing Helix Modules
```go
import std::io;
import std::io as io;
import std::future::Future;
```

### Importing Rust
```rs
/*
breaks down to the following c++ ir:
#RS-LINK[std::mem]
#RS-LINK[std::io as rust_io]
*/
using "rust" import std::mem;
using "rust" import std::io as rust_io;
```

### Importing C++
```go
using "c++" {
    import parse_json from "rapidjson.hpp"; // local header
    import "rapidjson.cpp";                 // local source
    import parse_json from <rapidjson.h>;   // global header (system)
    import <string> as cpp_string;          // global header (system)
}
```

### Importing Python
```julia
using "python" import tools::calc::add;
```

### Importing a single function
```py
import std::io::{println,print};
```

---

## Examples
```c++
using "python" import tools::calc as py_calc;
using "c++"    import <string> as cpp_string;
using "c"      import <stdio.h> as c_stdio;
using "rust"   import std::io::print as rust_print;

fn main() {
    let a: int = 5;
    let b: int = 10;
    let c: int = py_calc.add(a, b);
    print(f"added in python! {c}");

    let s: cpp_string = "Hello, World!";
    print(f"{s} from the C++ standard lib.");

    c_stdio.printf("Hello, World! from the C standard lib.\n");

    rust_print("Hello, World! from rust!");
}
```

the python part breaks down to this c++ equivalent code:
```cpp
#include <pybind11>

pybind11::py::module py_calc = pybind11::module::import("tools.calc");

int main() {
    int a = 5;
    int b = 10;
    int c = py_calc.attr("add")(a, b).cast<int>();
    helix::std::io::print(c);
}
```