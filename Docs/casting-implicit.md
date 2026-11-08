# Implicit Conversions

Some conversions need no `as`. Explicit conversions are covered in [Casting](/docs/language/casting/).

## Widening

[Integer and float widening](/docs/language/conversion-lattice/#2-the-rule-set) is implicit; no `as` required:

```kairo
var a: i32 = 42
var b: i64 = a       // implicit
```

`as` is permitted but redundant for widening conversions.

## Upcasting (derived to base)

[Derived-to-base pointer conversion](/docs/language/classes-inheritance/#inheritance) is implicit; no `as` required:

```kairo
class Animal { ... }
class Dog derives Animal { ... }

var dog = Dog("Rex", "Labrador")
var animal: *Animal = &dog   // implicit upcast
```

## See also

- [Casting](/docs/language/casting/)
- [Conversion Lattice](/docs/language/conversion-lattice/)
- [Type System](/docs/language/type-system/#implicit-conversions)
- [Primitives](/docs/language/primitives/)
- [Pointers](/docs/language/pointers/)
- [Classes: Inheritance](/docs/language/classes-inheritance/)
- [Implicit `op as`](/docs/language/operator-overloading/#implicit-op-as)
