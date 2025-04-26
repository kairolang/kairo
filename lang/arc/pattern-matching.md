# Pattern Matching
- switch
- match
- case
- default

---

## Table of Contents
- [Pattern Matching](#pattern-matching)
  - [Table of Contents](#table-of-contents)
    - [switch](#switch)
    - [match](#match)
  - [Examples](#examples)

---

### switch
```cpp
switch a {
    case 1: print("one"); // no fall through
    case 2 {
        print("two"); // fall through
        break;
    }
    default: print("default");
}
```

### match
```rs
let foo: string = match a { // no fall through at all
    AstNode(
        kind:  _,
        left:  "(",
        right: ")",
    ) -> {
        return "Contains Parenthesis";
    },

    AstNode(
        kind:  AST::Function,
        left:  _,
        right: _,
    ) -> "Is Function", // implicit return if no block

    AstNode(
        kind:  AST::Fish,
        left:  _,
        right: _,
    ) -> "Is Fish",

    "Hello" -> "Is Hello",

    let foo = "World" -> foo,

    let gish if gish.len() > 5 -> "Longer than 5",

    _ -> {
        return "Not Found";
    }
}
```

---

## Examples
```rs
#[no_entry]

let a: int = 1;

switch a {
    case 1: print("one");
    case 2 {
        print("two");
        break;
    }
    default: print("default");
} // prints "one"

let b: string = "Hello";

let foo: string = match b {
    "Hello" -> "Is Hello",
    "World" -> "Is World",
    _       -> "Not Found",
} // returns "Is Hello"
```
