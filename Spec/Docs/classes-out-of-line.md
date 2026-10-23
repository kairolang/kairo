# Forward Declarations and Out-of-Line Definitions

A class can be forward-declared without a body sufficient for `*Class` uses, not for `sizeof` or member
access:

```kairo
class Parser

class Lexer {
    var parser: unsafe *Parser   // ok: pointer to incomplete type
}

class Parser {
    var lexer: Lexer
    // full definition
}
```

Member methods can also be declared inside the class body without a body and defined out-of-line using
the `Class::method` qualified-name syntax:

```kairo
class Parser {
    var tokens: [Token]
    var pos: usize

    pub fn Parser(self, tokens: [Token])
    pub fn advance(self) -> Token
    pub fn peek(const self) -> Token
    priv fn error(self, msg: string) panic
}

fn Parser::Parser(self, tokens: [Token]) {
    self.tokens = tokens
    self.pos = 0
}

fn Parser::advance(self) -> Token {
    var t = self.tokens[self.pos]
    self.pos += 1
    return t
}

fn Parser::peek(const self) -> Token = self.tokens[self.pos]

fn Parser::error(self, msg: string) panic {
    panic std::Error::Parse(msg, self.pos)
}
```

This pattern keeps the class body small and readable as an API surface, with implementation details
defined separately.

## Rules

- The qualified definition's signature must exactly match the in-class declaration: parameter types,
  return type, and all function modifiers (`const`, `unsafe`, `panic`, `eval`, `async`, `inline`,
  `final`, `virtual`, `override`, `static`).
- **Visibility is omitted** from the out-of-line definition it is taken from the in-class declaration.
  Writing `pub fn Parser::advance` is a compile error.
- **Default arguments** must appear on the in-class declaration, not the out-of-line definition.
- Parameter names may differ between declaration and definition; the definition's names are used in the
  body.

## Generic classes

For [generic classes](/docs/language/classes/#generic-classes), the type parameters are re-declared on the out-of-line definition and the class
name carries its generic arguments:

```kairo
class <T> Vec {
    var data: unsafe *T
    var len: usize
    var cap: usize

    pub fn push(self, value: T)
    pub fn get(const self, i: usize) -> T
}

fn <T> Vec<T>::push(self, value: T) {
    if self.len == self.cap { self.grow() }
    self.data[self.len] = value
    self.len += 1
}

fn <T> Vec<T>::get(const self, i: usize) -> T = self.data[i]
```

## Operators, constructors, destructors

[Operator overloads](/docs/language/operator-overloading/), constructors, and destructors follow the same pattern:

```kairo
class Vec2 {
    var x: f64
    var y: f64

    pub fn Vec2(self, x: f64, y: f64)
    pub fn op delete(self)
    pub fn op +(self, other: Vec2) -> Vec2
}

fn Vec2::Vec2(self, x: f64, y: f64) {
    self.x = x
    self.y = y
}

fn Vec2::op delete(self) { /* ... */ }

fn Vec2::op +(self, other: Vec2) -> Vec2 = Vec2(self.x + other.x, self.y + other.y)
```

## Nested types

For methods on a nested type, chain the qualifiers:

```kairo
fn Outer::Inner::method(self) { /* ... */ }
```

---

## See also

- [Classes](/docs/language/classes/)
- [Class Lifecycle](/docs/language/classes-lifecycle/)
- [Inheritance and Virtual Dispatch](/docs/language/classes-inheritance/)
- [Generics](/docs/language/generics/)
- [Functions](/docs/language/functions/)
- [Operator Overloading](/docs/language/operator-overloading/)
