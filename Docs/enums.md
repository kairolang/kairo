# Enums

Enums define a closed set of named variants. In their simplest form, each variant is an integer discriminant
-- equivalent to a C++ `enum class`. Variants can also carry structured data (ADT enums), making them
Kairo's mechanism for type-safe tagged unions. Dispatch on variants with `match`. See
[Control Flow](/docs/language/control-flow#match) for the complete `match` syntax.

---

## Plain Enums

A plain enum is a set of named integer constants:

```kairo
enum Direction {
    North,
    East,
    South,
    West,
}

var dir = Direction::North
```

Variants are comma-separated and scoped to the enum name. The trailing comma is optional.

### Discriminant values

Variants are assigned sequential integers starting from 0 by default. Explicit values can be assigned
with `=`:

```kairo
enum HttpStatus {
    Ok = 200,
    NotFound = 404,
    InternalError = 500,
    ServiceUnavailable,   // 501
}
```

Discriminant expressions must be compile-time constants. Duplicate values are a compile error.

Compound expressions are valid for bit flags:

```kairo
enum FileMode derives u8 {
    Read    = 1 << 0,   // 1
    Write   = 1 << 1,   // 2
    Execute = 1 << 2,   // 4
    RW      = (Read | Write),       // 3
    All     = (Read | Write | Execute),  // 7
}

var perms: FileMode = .RW
if perms & FileMode::Read != 0 {
    // has read permission
}
```

---

## Underlying Type

The default underlying type is `u32`. The compiler promotes to a wider unsigned integer if the number of
variants exceeds what `u32` can represent, though a warning is emitted for enums exceeding 2^32 variants.

Specify an explicit underlying type with `derives` followed by an integer type:

```kairo
enum Opcode derives u8 {
    Nop  = 0x00,
    Load = 0x01,
    Store = 0x02,
    Halt = 0xFF,
}
```

Only integer types (`u8`, `u16`, `u32`, `u64`, `i8`, `i16`, `i32`, `i64`, `usize`, `isize`) are
permitted. The compiler errors if any discriminant does not fit in the specified type.

> [!NOTE]
> `derives` on an enum specifies the underlying integer type. This is distinct from `derives` on a
> [class](/docs/language/classes#inheritance), which declares inheritance.

---

## ADT Enums

Variants can carry structured data. Each payload is defined as a set of named fields inside braces:

```kairo
enum <T> ParseResult {
    Success { value: T, bytes_consumed: i32 },
    Error   { message: string, position: i32 },
    EndOfInput,
}
```

Variants without a payload (`EndOfInput` above) are plain discriminants. Variants with a payload carry
an anonymous struct alongside the discriminant. A single enum can freely mix both.

### Construction

ADT variants are constructed with the variant name followed by brace-delimited field assignment,
matching [struct](/docs/language/structures) aggregate initialization:

```kairo
var result = ParseResult<f64>::Success { value: 3.14, bytes_consumed: 4 }
var err = ParseResult<f64>::Error { message: "unexpected token", position: 12 }
var eof = ParseResult<f64>::EndOfInput
```

Field names are required. The order of fields in the initializer does not need to match the declaration
order.

When the enum type can be inferred from context, the `.Variant` shorthand works:

```kairo
var result: ParseResult<f64> = .Success { value: 3.14, bytes_consumed: 4 }
```

### Destructuring with `match`

Use `match` to dispatch on variants and extract payload fields. Destructured fields use `var` or `const`
to control mutability of the bound variable:

```kairo
match result {
    case .Success(var value, var bytes_consumed) {
        std::println(f"parsed {value} from {bytes_consumed} bytes")
    }
    case .Error(const message, const position) {
        std::println(f"error at {position}: {message}")
        // message = "other"  // compile error: message is const
    }
    case .EndOfInput {
        std::println("nothing left to parse")
    }
}
```

Field names in the destructuring pattern must match the names in the variant declaration. You can omit
fields you do not need the compiler does not require exhaustive field extraction:

```kairo
match result {
    case .Error(const message) {
        // only message is bound, position is ignored
        log_error(message)
    }
    // ...
    default { }
}
```

See [Control Flow](/docs/language/control-flow#match) for the full `match` syntax, including guards
(`where`), ranges, and expression form.

### `match` as an expression

ADT enums work in expression-form `match`. Each branch must produce the same type:

```kairo
var description = match result {
    case .Success(var value, var bytes_consumed) {
        f"parsed {value} ({bytes_consumed} bytes)"
    }
    case .Error(var message, var position) {
        f"error at {position}: {message}"
    }
    case .EndOfInput {
        "end of input"
    }
}
```

See [Control Flow](/docs/language/control-flow#match-as-an-expression) for the full expression-form
rules.

### Memory layout

An ADT enum stores a discriminant tag plus storage sized to the largest variant's payload. The tag is
the same integer type as the underlying type (default `u32`). A variant with no payload consumes no
extra storage beyond the tag.

```
ParseResult<f64> layout:
  [tag: u32] [payload: max(sizeof Success, sizeof Error)] [padding]
```

The compiler generates a destructor that switches on the tag to destroy the active variant's fields.
Copy and move operations follow the same pattern.

---

## Generic Enums

Enums with payloads can be generic. Type parameters are declared in angle brackets before the enum name:

```kairo
enum <K, V> LookupResult {
    Found    { key: K, value: V },
    NotFound { key: K },
    Error    { message: string },
}

var r = LookupResult<string, i32>::Found { key: "count", value: 42 }
```

Plain enums (no payloads) cannot be generic there is nothing for a type parameter to parameterize.

Constrain type parameters with `impl` or `derives` bounds:

```kairo
enum <T impl Serializable> CacheEntry {
    Valid   { data: T, expires: i64 },
    Expired { last_data: T },
    Empty,
}
```

See [Bounds](/docs/language/bounds) for the full constraint system.

---

## Shorthand Syntax

When the compiler can infer the enum type from context, the `.Variant` shorthand is available in
construction, `match` cases, comparison, and assignment:

```kairo
var dir: Direction = .North

match dir {
    case .North { go_up() }
    case .South { go_down() }
    case .East  { go_right() }
    case .West  { go_left() }
}

if dir == .North { ... }

dir = .South
```

The fully qualified form (`Direction::North`) always works and is required when the type cannot be
inferred.

---

## Comparison and Assignment

Enum values support equality comparison and assignment. Ordering operators (`<`, `>`, `<=`, `>=`) are
not available by default extend them if needed:

```kairo
var a = Direction::North
var b = Direction::South

if a == b { ... }    // ok
if a != b { ... }    // ok
// if a < b { ... }  // compile error: no ordering defined
```

For ADT enums, equality compares the tag only by default. Extend `op ==` to include payload comparison
if needed. See [Operators](/docs/language/operators#operator-overloading) for operator extension.

---

## Extends

Enums cannot contain methods in their body. Use `extend` blocks to add behavior, matching the same
pattern as [structs](/docs/language/structures#extends):

```kairo
enum LogLevel {
    Debug,
    Info,
    Warning,
    Error,
    Fatal,
}

extend LogLevel {
    fn is_severe(self) const -> bool {
        return self == .Error || self == .Fatal
    }

    fn prefix(self) const -> string {
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
interface Loggable {
    fn to_log_string(self) const -> string
}

extend LogLevel impl Loggable {
    fn to_log_string(self) const -> string {
        return self.prefix()
    }
}
```

The `extend` block and the enum definition must be in the same file. See
[Extends](/docs/language/extends) for the full `extend` system and
[Interfaces](/docs/language/interfaces) for interface declarations.

---

## No Associated Data in Variants (Plain Enums Only)

For plain enums without the `{ field: Type }` payload syntax, variants are strictly integer constants.
If you need per-variant data, use an [ADT enum](#adt-enums).

For untagged memory overlays where you manage the active member yourself, use
[Unions](/docs/language/unions).

---

## No Inheritance

Enums do not support inheriting from other enums. The `derives` keyword on an enum is reserved
exclusively for specifying the [underlying type](#underlying-type).

---

## Casting

Plain enum values can be cast to their underlying integer type and back:

```kairo
var dir = Direction::North
var raw = dir as u32           // 0

var back = raw as Direction    // Direction::North
```

Casting an integer to an enum that has no matching discriminant is undefined behavior.

ADT enums cannot be cast to integers directly they carry payloads that have no integer
representation. Cast the tag explicitly if you need the discriminant value.

See [Casting](/docs/language/casting) for the full casting model.

---

## Forward Declarations

Enums can be forward-declared when the underlying type is specified:

```kairo
enum Opcode derives u8    // forward declaration size is known

fn decode(op: Opcode) { ... }

enum Opcode derives u8 {
    Nop  = 0x00,
    Load = 0x01,
    Store = 0x02,
    Halt = 0xFF,
}
```

Without an explicit underlying type, forward declaration is not permitted the compiler needs the
size, which depends on the variant count and payload sizes.

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

// Construction
var r = LookupResult<string, i32>::Found { key: "count", value: 42 }

// Match with destructuring
match r {
    case .Found(var key, var value) {
        std::println(f"{key} = {value}")
    }
    case .NotFound(var key) {
        std::println(f"{key} not found")
    }
    case .Error(var message) {
        std::println(f"error: {message}")
    }
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
```