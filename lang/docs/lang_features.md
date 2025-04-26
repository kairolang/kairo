## this file defines all the language features of helix
# Language Features

### Interoperability
Helix has a very powerful interoperability feature that allows you to use anything from other languages like C, C++, Python, and Rust (What we will make). Or even extend the language to work with other languages.

```helix
ffi "c" import "stdio.h";
ffi "c++" import "iostream";
ffi "py" import os;
ffi "rs" import std::fs;
```

### OOP
Helix has all of OOP features like classes, interfaces, and inheritance.

```helix
interface Animal {
    fn speak(self) -> string;
}

class Base {
    fn Base() {
        print("Base created");
    }
}

#[impl(Animal)]
class Dog derives Base {
    fn Dog() {
        print("Dog created");
    }

    fn speak(self) -> string {
        return "Woof!";
    }
}

fn main() {
    let dog = Dog();
    let animal = dog as Base;

    print(Animal in dog); // true
    print(Animal in animal); // false

    print(dog derives Base); // true
    print(animal derives Base); // true
}
```

### Functional Programming
Helix has all of the functional programming features like higher-order functions, lambdas, closures, generators, and pattern matching.

```helix
fn add(a: int, b: int) -> int {
    return a + b;
}

fn closure_example() -> int {
    let a = 10;
    let b = 20;

    fn add_closure(a: int, b: int) -> int { /// this does not have access to the outer scope
        return a + b;
    }

    let other_closure = fn(a: int, b: int) -> int { /// this does have access to the outer scope
        return a + b;
    };

    /// both the closures can be used as higher-order functions

    return add_closure(a, b);
}

fn generator() -> yield int {
    for i in 0..10 {
        yield i;
    }
}

fn main() {
    let a = 10;
    let b = 20;

    let c = match a {
        10 -> 1;
        20 -> 2;
        _  -> 3;
    };
}
```

### Null Safety
Helix by default is null safe, and you can use the `?` operator to specify that a value can be null.

```helix
fn add(a: int?, b: int?) -> int? {
    if a? && b? {
        return a + b;
    } else {
        return null;
    }
}
```

### Generics
Generics in helix are handled in a way that is complexly unique to the language.

```helix
fn add(a: T, b: T) -> T
  requires <T> if Add in T {
    return a + b;
}

fn call_a_string_method(a: T) -> T
  requires <T> if T derives string {
    return a.to_uppercase();
}

fn call_a_method(a: T) -> string {
    try:
        return string(a);
    catch:
        return "Error";
}
```

Things to note here:
1. The `requires` keyword is used to specify the constraints on the generic type.
2. The `if` keyword is used to specify the condition that the generic type must satisfy. (optional)
3. The `derives` keyword is a strict constraint that the generic type must satisfy, it is used to specify that the generic type MUST derive from a specific type.
4. The `in` keyword is used to specify that the generic type must implement the specified type's methods (not necessarily derive from the type).


### Pattern Matching
Pattern matching in helix is very powerful and can be used in a variety of ways.

```helix
fn match_example(a: AST_Node) -> int? {
    match a {
        AST_Node(
            type: "int",
            value: _,
            children: _
        ) -> 1;

        AST_Node(
            type: "float",
            value: _,
            children: _
        ) -> 2;

        AST_Node(
            type: "string",
            value: _,
            children: _
        ) -> 3;

        _ -> null;
    }
}
```

Things to note here:
1. The `match` keyword is used to start a pattern matching block.
2. The `->` operator is used to specify the return value of the function if the pattern matches.
3. The `_` operator is used to specify that the value is not important and can be anything.
4. The `null` keyword is used to specify that the pattern did not match any of the cases.
5. The `AST_Node` is a custom type that is defined in the codebase.
6. The `type`, `value`, and `children` are fields of the `AST_Node` type.
7. The `int?` return type specifies that the function can return an integer or null.

### Types
Helix has a very powerful type system that allows for easy and safe programming. and closely resembles type annotations in python.

```helix
fn add(a: int, b: int) -> int | float {
    if a % 2 == 0:
        return a + b;
    else:
        return (a as float) + (b as float);
}
```

Things to note here:
1. The `int | float` return type specifies that the function can return either an integer or a float.
2. The `as` keyword is used to cast a value to a different type.

### Finally (== defer)
Helix has a `finally` keyword that can be used to execute a block of code after the function has completed execution.

```helix
fn example() -> int {
    unsafe let sm_ptr* = malloc(10);
    finally: delete sm_ptr;

    finally {
        print("1");
        print("2");
        print("3");
    }

    print("4");
    print("5");
    print("6");

    return 0;
}

// Output:
// 4
// 5
// 6
// 1
// 2
// 3
```

Things to note here:
1. The `finally` keyword is used to start a finally block.
2. The code inside the finally block will be executed after the function has completed execution.
3. This is really useful for code readability since you can put all the cleanup code right next to the code that needs to be cleaned up.

### UDTs (User Defined Types)
Helix has all of OOP features like classes, interfaces, and inheritance.

```helix
interface Animal {
    fn speak() -> string;
}

abstract Mammal derives Animal {
    fn speak() -> string {
        return "I am a mammal";
    }

    abstract fn walk() -> string;
}

class Dog derives Mammal {
    fn speak() -> string {
        return "Woof!";
    }

    fn walk() -> string {
        return "I am walking";
    }
}

class Cat derives Mammal {
    fn speak() -> string {
        return "Meow!";
    }
}

fn print_mammal(m: T) requires <T> if T derives Mammal {
    print(m.speak());
    print(m.walk());
}

fn main() {
    let dog = Dog();
    let cat = Cat();

    print_mammal(dog); // will only compile if the type implements Mammal
}
```

Things to note here:
1. The `interface` keyword is used to define an interface.
2. The `abstract` keyword is used to define an abstract class.
3. The `derives` keyword is used to specify that a class implements an interface or derives from an abstract class.
4. The `class` keyword is used to define a class.
5. The `implements` keyword is used to specify that a class implements an interface.
6. The `T` is a generic type that is used to specify that the function can accept any type that derives from `Mammal`.
7. The `requires` keyword is used to specify the constraints on the generic type.
8. The `if` keyword is used to specify the condition that the generic type must satisfy.

### Macros
Helix has 3 types of macros:
1. Function-like macros            - untyped
2. Attribute-like macros           - typed
3. Procedural Function-like macros - typed

```helix
// this is a function-like macro
macro hello_world! {
    print("Hello, World!");
};

// this is a function-like macro
macro div_by_2!(a) {
    a / 2
};

macro add!(a: Int!, b: Int!) {
    // this is a procedural macro
}

macro #serialize(a: AST::Tree) -> AST::Tree {
    // this is a procedural macro
}

#[serialize]
struct somehting {
    let a: int;
    let b: int;
}

fn main() {
    hello_world!;

    let a = 10;
    let b = div_by_2!(a);

    print(b);
}
```

Things to note here:
1. The `macro` keyword is used to define a macro.
2. The `!` operator is used to call a macro.
3. The `#` operator is used to specify that the macro is an attribute-like macro.
4. The `->` operator is used to specify the return type of the macro.
5. if the macro parameters are not typed, its a simple function-like preprocessor macro.
6. if the macro parameters are typed and have a `!` operator, its a function-like procedural macro.
7. if the macro parameters are typed and have a `#` operator, its an attribute-like procedural macro.

### Casting
Helix allows for multiple types of casting.

```helix
let a: int = 10;

let const b: int = a as const int;

// the following casts can happen
a as float;       // regular cast
a as *int;        // pointer cast (safe, returns a pointer if the memory is allocated else *null)
a as &int;        // reference cast (safe, returns a reference if the memory is allocated else &null)
a as unsafe *int; // unsafe pointer cast (raw memory access)
a as const int;   // const cast (makes the value immutable)
a as int;         // removes the const qualifier if present else does nothing

/// any other type of casting is not allowed.
```

Things to note here:
1. The `as` keyword is used to cast a value to a different type.

