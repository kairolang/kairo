# Pattern Matching

`match` is Kairo's multi-way dispatch construct. It handles value matching, enum variant dispatch, ADT destructuring, struct field extraction, and range checks all with compiler-enforced exhaustiveness.

```kairo
match status_code {
    case 200 { std::println("OK") }
    case 404 { std::println("Not Found") }
    case 500 { std::println("Internal Server Error") }
    default  { std::println(f"Unknown: {status_code}") }
}
```

## Value matching

`match` operates on integers, [strings](/docs/language/primitives/#strings), and booleans by comparing against literal values:

```kairo
match command {
    case "start" { engine.start() }
    case "stop"  { engine.stop() }
    case "reset" { engine.reset() }
    default      { log_unknown(command) }
}

match is_valid {
    case true  { proceed() }
    case false { abort() }
}
```

## Enum variant matching

For [plain enums](/docs/language/enums-plain/), use the [`.Variant` shorthand](/docs/language/enums/#shorthand-syntax) when the type is inferred from the match operand:

```kairo
match dir {
    case .North { go_up() }
    case .South { go_down() }
    case .East  { go_right() }
    case .West  { go_left() }
}
```

The fully qualified form `Direction::North` also works. The compiler verifies all variants are covered.

## ADT destructuring

ADT enum variants carry payloads. Destructure them in `match` with `var` or `const` bindings inside parentheses. Field names must match the variant declaration:

```kairo
enum <K, V> LookupResult {
    Found    { key: K, value: V },
    NotFound { key: K },
    Error    { message: string },
}

match result {
    case .Found(var key, var value) {
        std::println(f"{key} = {value}")
    }
    case .NotFound(var key) {
        std::println(f"{key} not found")
    }
    case .Error(const message) {
        // message cannot be reassigned bound as const
        log_error(message)
    }
}
```

You can omit fields you do not need exhaustive field extraction is not required:

```kairo
match result {
    case .Found(var value) {
        // only value is bound, key is ignored
        process(value)
    }
    default { }
}
```

See [Enums](/docs/language/enums-adt/) for ADT enum declarations and construction.

## `where` guards

Append [`where`](/docs/language/where/#where-in-match) followed by a boolean expression to add a condition to a case. The branch only matches if both the pattern and the guard are satisfied:

```kairo
match result {
    case .Found(var key, var value) where value > 0 {
        std::println(f"{key} has positive value")
    }
    case .Found(var key, var value) {
        std::println(f"{key} has non-positive value")
    }
    default { }
}
```

Guards work the same way in a value-form `match`, written before the arrow:

```kairo
var amount = match result {
    case .Found(var key, var value) where value > 0 => value
    default => 0
}
```

Guards are evaluated after the pattern matches. A case with a guard that fails falls through to the next case this is the only situation where control moves between cases.

## Struct matching

[Structs](/docs/language/structures/) have a single shape (no variants), so `match` on a struct is [destructuring](/docs/language/structures/#destructuring) combined with guards. A struct `case` without a `where` guard always matches and is a compile error unless it is the only case or the last case (acting as a catch-all):

```kairo
struct Response {
    var status: i32
    var body: string
}

match response {
    case Response(var status, var body) where status == 200 {
        process(body)
    }
    case Response(var status) where status >= 400 {
        log_error(f"HTTP {status}")
    }
    default {
        // catch-all
    }
}
```

## Range matching

Integer cases can match a [range](/docs/language/operators/#ranges) using `..` (exclusive end) or `..=` (inclusive end):

```kairo
match http_status {
    case 200..=299 { std::println("success") }
    case 300..=399 { std::println("redirect") }
    case 400..=499 { std::println("client error") }
    case 500..=599 { std::println("server error") }
    default        { std::println("unknown") }
}
```

The same ranges in a value-form `match`:

```kairo
var kind = match http_status {
    case 200..=299 => "success"
    case 300..=399 => "redirect"
    case 400..=599 => "error"
    default => "unknown"
}
```

## Matching a nullable

A `match` on a [nullable](/docs/language/nullables/) `T?` must answer null first: its first arm is `case null`, on its own and with no `where` guard. A first arm that is anything else is a compile error (not a warning). When the match has no `case null` at all, the fix-it inserts `case null { }` at the top (in expression form, where the arm needs a value, the error says to add `case null => <value>`); when `case null` is further down, or shares its arm with other patterns, the error points at it. Because null is answered once, at the top, every later arm, `default` included, sees the value as non-null:

```kairo
match port {                    // port: i32?
    case null { use_default() } // port is null here
    case 0    { pick_free() }   // a value pattern only matches a present value
    default   { bind(port) }    // port is non-null: case null took null
}
```

A binding pattern binds the unwrapped value, so `case var v` on an `i32?` binds `v: i32` and never matches null:

```kairo
var label = match port {
    case null                    => "none"
    case var p where p < 1024    => f"system port {p}"   // p: i32
    default                      => f"port {port}"        // port reads as i32
}
```

A `where` guard narrows its arm the same way an `if` condition does. After the `match`, the value's null state is the merge of every arm that can fall through. A second `case null` is an error: the first arm already answered null. Exhaustiveness is checked over `T`, so a `bool?` with `case null`, `case true` and `case false` needs no `default`.

## `match` as an expression

```kairo
var label = match level {
    case .Debug   => "debug"
    case .Info    => "info"
    case .Warning => "warning"
    case .Error   => "error"
    case .Fatal   => "fatal"
}

var priority = match code {
    case 200..=299 => 0
    case 400..=499 => 1
    case 500..=599 => 2
    default        => -1
}

var message = match result {
    case .Found(var key, var value) => f"{key}: {value}"
    case .NotFound(var key)         => f"{key} not found"
    case .Error(var message)        => message
}
```

Each arm is `case pattern => value` or `default => value`. All arms must produce the same type.

- Arms are not separated by commas. A comma between arms is an error ([S076E](/docs/language/diagnostics/#s076e-match-arms-separated-by-a-comma)).
- Guards come before the arrow: `case .Found(var v) where v > 0 => v`.
- You may break before or after `=>`.
- A `match` closes with `}`, so it can be used directly as an operand: `var n = match k { ... } + 1`. The [parentheses rule](/docs/language/control-flow/#how-far-an-arm-extends) for `if` and `try` does not apply to it.
- All arms of one `match` use the same form, either all `=>` or all `{ }`. Mixing the two is an error ([S075E](/docs/language/diagnostics/#s075e-match-arms-mix--and---forms)).
- In statement position, a `match` whose arms are all `=>` is an expression, and exhaustiveness is required as for any `match` expression. A `match` with block arms is a statement.

In expression form, exhaustiveness is required every possible value must be covered. For integers and strings, this means `default` is mandatory.

## Exhaustiveness

The compiler verifies that all possible values are covered:

| Matched type | Coverage rule |
|---|---|
| Plain enum | All variants covered, or `default` present |
| ADT enum | All variants covered, or `default` present |
| Integers / strings | `default` always required |
| Booleans | `true` + `false` covers it |
| Structs | `default` always required |
| Nullable `T?` | `case null` first, then the rule for `T` |

A `default` case matches any value not covered by preceding cases. It must be the last case.

A match whose arms are all `=>` is an expression, wherever it appears.

## No fall-through

Each case is an isolated block. There is no fall-through between cases and no `@fallthrough` attribute. If you need multiple values to execute the same code, list them in a single case separated by commas:

```kairo
match priority {
    case 1, 2, 3 { handle_high() }
    case 4, 5    { handle_medium() }
    default      { handle_low() }
}
```

## `break` in `match` inside a loop

Inside a `match` nested within a loop, [`break`](/docs/language/control-flow/#break-and-continue) exits the **loop**, not the match. Match cases are already isolated blocks with no fall-through, so there is nothing to "break" out of within the match itself.

```kairo
for item in items {
    match item.kind {
        case .Sentinel {
            break   // exits the for loop
        }
        case .Data(var payload) {
            process(payload)
        }
        default { }
    }
}
```

---

## See also

- [Control Flow](/docs/language/control-flow/)
- [Enums](/docs/language/enums/)
- [ADT Enums](/docs/language/enums-adt/)
- [Plain Enums](/docs/language/enums-plain/)
- [Structures](/docs/language/structures/)
- [`where`](/docs/language/where/)
- [Nullables](/docs/language/nullables/)
- [Diagnostics](/docs/language/diagnostics/)
