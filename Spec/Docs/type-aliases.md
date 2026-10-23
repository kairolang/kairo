# Type Aliases

`type` declares a transparent alias for an existing type. The alias and the original type are fully
interchangeable:

```kairo
type Byte = u8
type <T> Matrix = [[T]]
type <T> TokenVec = [T]

var b: Byte = 42        // Byte and u8 are the same type
var m: Matrix<f64> = [[1.0, 2.0], [3.0, 4.0]]
var v: TokenVec<i32> = [1, 2, 3]
```

Aliases can be [generic](/docs/language/generics/). Type parameters are declared in angle brackets before the alias name.

Type aliases are transparent (unless `-fno-type-aliasing` is set) the alias and the original type
are the same type for identity purposes.

## Strict aliasing mode

By default, aliases are transparent. The `-fno-type-aliasing` compiler flag makes aliases into distinct
types that require explicit construction:

```kairo
type MyString = string

// With -ftype-aliasing (default):
var a: string = "hello"
var b: MyString = a        // ok: transparent alias

// With -fno-type-aliasing:
var a: string = "hello"
var b: MyString = MyString(a) // explicit construction required
b = a                         // compile error: type mismatch
```

## Aliases cannot widen visibility

An alias introduces a second *name* for a type, not a second type. It may not be [more visible](/docs/language/modules/#visibility-on-top-level-declarations) than
the type it names an alias that published a `priv` type under a `pub` name would hand callers a
type its author never exported:

```kairo
priv struct Base1 {
    var x: i32
}

pub type Base2 = Base1      // compile error: pub alias names a priv type
pub type Base3 = *Base1     // so does this
priv type Base4 = Base1     // ok: no wider than its target
```

Every name the alias mentions counts, not only the outermost one. A pointer, nullable, vector, slice, set,
tuple, array, map, function-pointer parameter or return, and a generic argument all publish their
target just as directly, and so does a private module used as a path segment:

```kairo
priv module M {
    pub struct T { var a: i32 }
}

pub type Leak = M::T        // compile error: reaches T through a priv module
```

The rule applies through chains, since an alias of an alias is still a name for the same type:

```kairo
priv type Inner = Config
pub  type Outer = Inner     // compile error: Inner is priv
```

The error is reported at the alias, not at each use of it. To expose a restricted view of a private
type rather than the type itself, declare a wrapper with the members you mean to publish an alias
cannot narrow what it names.

## Restrictions

Type aliases must reference existing named types. Inline anonymous type definitions are not permitted:

```kairo
type Pair = (i32, i32)                // ok: aliases a tuple type
// type Anon = struct { var x: i32 }  // compile error: cannot alias anonymous type definitions
```

If you need a named struct, [declare a struct](/docs/language/structures/). Type aliases are for giving new names to existing types,
not for defining new ones.

A chain of aliases may be at most 64 links deep before the compiler stops following it. Raise the
limit with `--cmax-type-alias-depth=<n>` if a generated or re-exported chain legitimately needs more.

## See also

- [Type System](/docs/language/type-system/)
- [Generics](/docs/language/generics/)
- [Modules](/docs/language/modules/)
- [Primitives](/docs/language/primitives/)
- [Collections](/docs/language/collections/)
- [Structures](/docs/language/structures/)
