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

fn main() -> i32 {
    var dir = Direction::North
    return 0
}
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

A discriminant is an integer constant expression evaluated by the compiler: literals, `+ - * | & ^ << >>`,
unary `-` and `~`, parentheses, `as` to an integer type, and earlier variants of the same enum. Inside a
discriminant, an earlier variant has the enum's [underlying type](#underlying-type), so `Exec = Read << 2`
and `RW = Read | Write` work. `~` works in the underlying type: `All = ~0` in a `u32` enum is `0xFFFFFFFF`.
A variant without a discriminant is the previous value plus one, or 0 if it is first.

A value that doesn't evaluate or doesn't fit the underlying type is
[SC128E](/docs/language/diagnostics#sc128e-an-enum-discriminant-does-not-evaluate-or-does-not-fit). Two
variants with the same value is
[SC130E](/docs/language/diagnostics#sc130e-two-variants-of-an-enum-have-the-same-value); imported C++
enums are exempt.

Compound expressions are valid for bit flags:

```kairo
enum FileMode derives u8 {
    Read    = 1 << 0,   // 1
    Write   = 1 << 1,   // 2
    Execute = 1 << 2,   // 4
    RW      = (Read | Write),       // 3
    All     = (Read | Write | Execute),  // 7
}

fn main() -> i32 {
    var perms: FileMode = .RW
    if (perms as u8 & FileMode::Read as u8) != 0 {
        // has read permission
    }
    return 0
}
```

Bitwise operators are not defined on the enum type itself, so test a flag on the underlying integer:
cast both sides with `as` and compare the result with `0`.

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

> [!NOTE]
> A non-generic payload enum whose payload holds a type whose copy, move and destruction are not known
> until instantiation (such as `Box<i32>` for a generic class `Box`) is not compiled yet. See [Status](/docs/status#not-compiled-yet).

### Construction

There are three construction forms:

| Form | Use |
|---|---|
| `Enum::V { f: e }` | Payload variant, fully qualified |
| `.V { f: e }` | Payload variant, enum type inferred from context |
| `.V` (or `Enum::V`) | Variant with no payload |

A payload variant written without braces, braces on a variant without a payload, a missing field, or a
field given twice is [SC131E](/docs/language/diagnostics#sc131e-a-variant-is-built-with-the-wrong-shape).

`Enum::V { field: value }` builds a payload variant anywhere; `.V { field: value }` and `.V` work where the
expected type is known. A nullary variant takes no braces.

ADT variants are constructed with the variant name followed by brace-delimited field assignment,
matching [struct](/docs/language/structures) aggregate initialization:

```kairo
enum <T> ParseResult {
    Success { value: T, bytes_consumed: i32 },
    Error   { message: string, position: i32 },
    EndOfInput,
}

fn main() -> i32 {
    var result = ParseResult<f64>::Success { value: 3.14, bytes_consumed: 4 }
    var err = ParseResult<f64>::Error { message: "unexpected token", position: 12 }
    var eof = ParseResult<f64>::EndOfInput

    // the enum type is known from the declaration, so the shorthand works
    var inferred: ParseResult<f64> = .Success { value: 3.14, bytes_consumed: 4 }
    return 0
}
```

Field names are required. The order of fields in the initializer does not need to match the declaration
order.

### Destructuring with `match`

Use `match` to dispatch on variants and extract payload fields. Destructured fields use `var` or `const`
to control mutability of the bound variable:

```kairo
enum <T> ParseResult {
    Success { value: T, bytes_consumed: i32 },
    Error   { message: string, position: i32 },
    EndOfInput,
}

fn report(result: ParseResult<f64>) -> string {
    match result {
        case .Success(var value, var bytes_consumed) {
            return f"parsed {value} from {bytes_consumed} bytes"
        }
        case .Error(const message, const position) {
            // message = "other"  // compile error: message is const
            return f"error at {position}: {message}"
        }
        case .EndOfInput {
            return "nothing left to parse"
        }
    }
}
```

> [!NOTE]
> The current compiler does not report assigning to a `const` pattern binding yet. See
> [Status](/docs/status#not-diagnosed).

Field names in the destructuring pattern must match the names in the variant declaration. You can omit
fields you do not need the compiler does not require exhaustive field extraction:

```kairo
enum <T> ParseResult {
    Success { value: T, bytes_consumed: i32 },
    Error   { message: string, position: i32 },
    EndOfInput,
}

fn error_message(result: ParseResult<f64>) -> string {
    match result {
        case .Error(const message) {
            // only message is bound, position is ignored
            return message
        }
        default { return "" }
    }
}
```

See [Control Flow](/docs/language/control-flow#match) for the full `match` syntax, including guards
(`where`), ranges, and expression form.

### `match` as an expression

```kairo
enum <T> ParseResult {
    Success { value: T, bytes_consumed: i32 },
    Error   { message: string, position: i32 },
    EndOfInput,
}

fn describe(result: ParseResult<f64>) -> string {
    return match result {
        case .Success(var value, var bytes_consumed) => f"parsed {value} ({bytes_consumed} bytes)"
        case .Error(var message, var position) => f"error at {position}: {message}"
        case .EndOfInput => "end of input"
    }
}
```

ADT enums work in expression-form `match`. Each arm is `case pattern => value`, and every arm must produce
the same type.

See [Control Flow](/docs/language/control-flow#match-as-an-expression) for the full expression-form
rules.

### Memory layout

An ADT enum stores a discriminant tag plus storage sized to the largest variant's payload. The tag is
a `u32`. A variant with no payload consumes no extra storage beyond the tag.

> [!NOTE]
> A `derives` type on an enum with payloads is accepted but ignored for now: the tag stays `u32`. See
> [Status](/docs/status#not-compiled-yet).

```
ParseResult<f64> layout:
  [tag: u32] [payload: max(sizeof Success, sizeof Error)] [padding]
```

The compiler generates a destructor that switches on the tag to destroy the active variant's fields.
Copy and move operations follow the same pattern.

### Lifecycle category

An enum whose variants carry payloads follows the struct rule for lifecycle: its
[category](/docs/language/classes#lifecycle-categories) is the weakest of its payload fields' categories
(COPY, then MOVE, then NON_TRANSFER), and it is trivially copyable or destructible only when every
payload is. A plain enum is COPY.

---

## Generic Enums

Enums with payloads can be generic. Type parameters are declared in angle brackets before the enum name:

```kairo
enum <K, V> LookupResult {
    Found    { key: K, value: V },
    NotFound { key: K },
    Error    { message: string },
}

fn main() -> i32 {
    var r = LookupResult<string, i32>::Found { key: "count", value: 42 }
    return 0
}
```

Plain enums (no payloads) cannot be generic there is nothing for a type parameter to parameterize.

Constrain type parameters with `impl` or `derives` bounds:

```kairo
interface Serializable {
    fn serialize(const self) -> [byte]
}

enum <T impl Serializable> CacheEntry {
    Valid   { data: T, expires: i64 },
    Expired { last_data: T },
    Empty,
}
```

See [Requires Clauses](/docs/language/requires) for the full constraint system.

---

## Shorthand Syntax

When the compiler can infer the enum type from context, the `.Variant` shorthand is available in
construction, `match` cases, comparison, and assignment:

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

The fully qualified form (`Direction::North`) always works and is required when the type cannot be
inferred.

`.V` takes its enum from the type expected where it is written:

- an initializer with a declared type: `var d: Dir = .North`
- a `return` in a function with a declared return type
- a call argument, which takes the parameter's type

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

As an argument, `.V` matches a parameter only if that parameter's enum has a variant `V`; this is how
an overload is chosen. If more than one overload's enum has `V`, the call is ambiguous
([SC064E](/docs/language/diagnostics#call-to-f-is-ambiguous-more-than-one-candidate-matches-at-the-same-rank)). A
generic parameter `T` gives `.V` no enum to take, so no overload matches (SC063E); write the variant in
full, `Dir::North`:

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

A `.V` with nothing to give it an enum type, against a type that is not an enum, or naming a variant the
enum does not have is
[SC123E](/docs/language/diagnostics#sc123e-a-variant-name-does-not-fit-the-expected-type).

---

## Comparison and Assignment

Enum values support equality comparison and assignment. Ordering operators (`<`, `>`, `<=`, `>=`) are
not available by default extend them if needed:

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

`==` and `!=` on enums are built in and compare which variant is active, ignoring payloads. They satisfy
`Equatable` the same way integer comparison does; no operator declaration is involved.

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
enum Direction { North, East, South, West }

fn main() -> i32 {
    var dir = Direction::North
    var raw = dir as u32           // 0

    var back = raw as Direction    // Direction::North
    return 0
}
```

Casting an integer to an enum that has no matching discriminant is undefined behavior.

ADT enums cannot be cast to integers directly they carry payloads that have no integer
representation. Cast the tag explicitly if you need the discriminant value.

See [Casting](/docs/language/casting) for the full casting model.

---

## Forward Declarations

Enums can be forward-declared when the underlying type is specified:

```kairo
enum Opcode derives u8    // forward declaration: size is known

fn is_halt(code: Opcode) -> bool { return code == .Halt }

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