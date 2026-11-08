# Enums

Enums define a closed set of named variants. In their simplest form, each variant is an integer discriminant, equivalent to a C++ `enum class`. Variants can also carry structured data ([ADT enums](/docs/language/enums-adt/)), making them Kairo's mechanism for type-safe tagged unions. Dispatch on variants with `match`. See [Control Flow](/docs/language/pattern-matching/) for the complete `match` syntax.

## In this section

- [Plain Enums](/docs/language/enums-plain/): named integer constants, discriminant values, underlying types, casting, and forward declarations.
- [ADT Enums](/docs/language/enums-adt/): variants with payloads, construction, destructuring with `match`, memory layout, lifecycle, generic enums, and casting.

---

## Shorthand Syntax

When the compiler can infer the enum type from context, the `.Variant` shorthand is available in construction, `match` cases, comparison, and assignment:

```kairo
enum Direction { North, East, South, West }

fn go_up() { }
fn go_down() { }
fn go_right() { }
fn go_left() { }

fn main() -> i32 {
    var dir: Direction = .North

    match dir {
        case .North { go_up() }
        case .South { go_down() }
        case .East  { go_right() }
        case .West  { go_left() }
    }

    if dir == .North { go_up() }

    dir = .South
    return 0
}
```

The fully qualified form (`Direction::North`) always works and is required when the type cannot be inferred.

`.V` takes its enum from the type expected where it is written:

- an initializer with a declared type: `var d: Dir = .North`
- a `return` in a function with a declared return type
- a call argument, which takes the parameter's type
- the other operand of `==` or `!=`, on either side: `.North == d` is `d == .North`. Two shorthands compared with each other (`.A == .B`) have no enum to take and are an error (SC123E)

```kairo
enum Dir { North, East, South, West }
enum Light { Red, Green }

fn turn(d: Dir) { }
fn set(l: Light) { }
fn set(d: Dir) { }
fn <T> log(x: T) { }

fn opposite(d: Dir) -> Dir {
    return .South                  // return with a declared return type
}

fn main() -> i32 {
    var d: Dir = .North            // initializer with a declared type
    turn(.West)                    // call argument
    set(.Green)                    // only Light has Green: picks set(l: Light)
    set(.East)                     // only Dir has East: picks set(d: Dir)
    log(Dir::North)                // generic parameter: write the enum in full
    return 0
}
```

As an argument, `.V` matches a parameter only if that parameter's enum has a variant `V`; this is how an [overload](/docs/language/functions-overloading/) is chosen. If more than one overload's enum has `V`, the call is ambiguous ([SC064E](/docs/language/diagnostics/#call-to-f-is-ambiguous-more-than-one-candidate-matches-at-the-same-rank)). A generic parameter `T` gives `.V` no enum to take, so no overload matches (SC063E); write the variant in full, `Dir::North`:

```kairo
enum Dir { North, South }
enum Pole { North, Equator }

fn go(d: Dir) { }
fn go(p: Pole) { }
fn <T> log(x: T) { }

fn main() -> i32 {
    go(.North)      // error SC064E: both Dir and Pole have North
    log(.North)     // error SC063E: T gives .North no enum type
    return 0
}
```

A `.V` with nothing to give it an enum type, against a type that is not an enum, or naming a variant the enum does not have is [SC123E](/docs/language/diagnostics/#sc123e-a-variant-name-does-not-fit-the-expected-type).

---

## Comparison and Assignment

Enum values support equality comparison and assignment. Ordering operators (`<`, `>`, `<=`, `>=`) are not available by default [extend](/docs/language/extends/#enums) them if needed:

```kairo
enum Direction { North, East, South, West }

fn main() -> i32 {
    var a = Direction::North
    var b = Direction::South

    var same = a == b        // ok: false
    var differ = a != b      // ok: true
    // var before = a < b    // compile error: no ordering defined
    return 0
}
```

`==` and `!=` on enums are built in and compare which variant is active, ignoring payloads. They satisfy `Equatable` the same way integer comparison does; no operator declaration is involved.

---

## Extends

Enums cannot contain methods in their body. Use `extend` blocks to add behavior, matching the same pattern as [structs](/docs/language/structures/#extends):

```kairo
enum LogLevel {
    Debug,
    Info,
    Warning,
    Error,
    Fatal,
}

extend LogLevel {
    fn is_severe(const self) -> bool {
        return self == .Error || self == .Fatal
    }

    fn prefix(const self) -> string {
        match self {
            case .Debug   { return "[DEBUG]" }
            case .Info    { return "[INFO]" }
            case .Warning { return "[WARN]" }
            case .Error   { return "[ERROR]" }
            case .Fatal   { return "[FATAL]" }
        }
    }

    static fn from_string(s: string) -> LogLevel {
        match s {
            case "debug"   { return .Debug }
            case "info"    { return .Info }
            case "warning" { return .Warning }
            case "error"   { return .Error }
            case "fatal"   { return .Fatal }
            default        { return .Info }
        }
    }
}
```

### What extends can add

| Allowed | Not allowed |
|---|---|
| Methods | Constructors |
| Static functions | Destructors |
| Comparison / arithmetic operators | Copy / move assignment |
| `fn op as` (type conversion) | |

### Interface conformance

Enums can implement interfaces through `extend ... impl`:

```kairo
enum LogLevel { Debug, Info, Warning, Error, Fatal }

interface Loggable {
    fn to_log_string(const self) -> string
}

extend LogLevel impl Loggable {
    fn to_log_string(const self) -> string {
        if self == .Error || self == .Fatal { return "severe" }
        return "normal"
    }
}
```

The `extend` block and the enum definition must be in the same file. See [Extends](/docs/language/extends/) for the full `extend` system and [Interfaces](/docs/language/interfaces/) for interface declarations.

---

## No Inheritance

Enums do not support inheriting from other enums. The `derives` keyword on an enum is reserved exclusively for specifying the [underlying type](/docs/language/enums-plain/#underlying-type).

---

## Summary

```kairo
// Plain enum
enum Direction {
    North, East, South, West,
}

// Explicit discriminants + underlying type
enum Opcode derives u8 {
    Nop  = 0x00,
    Load = 0x01,
    Store = 0x02,
    Halt = 0xFF,
}

// Bit flags
enum FileMode derives u8 {
    Read    = 1 << 0,
    Write   = 1 << 1,
    Execute = 1 << 2,
    All     = (Read | Write | Execute),
}

// ADT enum with payloads
enum <K, V> LookupResult {
    Found    { key: K, value: V },
    NotFound { key: K },
    Error    { message: string },
}

// Extended with methods
extend Direction {
    fn opposite(self) -> Direction {
        match self {
            case .North { return .South }
            case .South { return .North }
            case .East  { return .West }
            case .West  { return .East }
        }
    }
}

fn main() -> i32 {
    // Construction
    var r = LookupResult<string, i32>::Found { key: "count", value: 42 }

    // Match with destructuring
    match r {
        case .Found(var key, var value) {
            var line = f"{key} = {value}"
        }
        case .NotFound(var key) {
            var line = f"{key} not found"
        }
        case .Error(var message) {
            var line = f"error: {message}"
        }
    }

    var back = Direction::North.opposite()
    return 0
}
```

## See also

- [Plain Enums](/docs/language/enums-plain/)
- [ADT Enums](/docs/language/enums-adt/)
- [Extends](/docs/language/extends/)
- [Interfaces](/docs/language/interfaces/)
- [Control Flow](/docs/language/pattern-matching/)
- [Unions](/docs/language/unions/)
- [Casting](/docs/language/casting/#enum-casts)
