| **N** | **Control Flow** | **Primitives**    | **Types** | **Decls** | **UDTs**   | **Modifiers** | **Specifiers** | **Visibility** |
|-------|------------------|-------------------|-----------|-----------|------------|---------------|----------------|----------------|
|   1   | `match`          | `u8`     `i8`     | `string`  | `var`     | `interface`| `unsafe`      | `async`        | `pub`          |
|   2   | `case`           | `u16`    `i16`    | `map`     | `fn`      | `class`    | `override`    | `const`        | `priv`         |
|   3   | `default`        | `u32`    `i32`    | `vec`     | `op`      | `struct`   | `final`       | `inline`       | `prot`         |
|   4   | `return`         | `u64`    `i64`    | `list`    | `ffi`     | `extend`   |               | `static`       |                |
|   5   | `if`             | `u128`   `i128`   | `array`   | `module`  | `enum`     |               | `thread`       |                |
|   6   | `unless`         | `u256`   `i256`   | `set`     | `test`    | `type`     |               | `eval`         |                |
|   7   | `else`           | `usize`  `isize`  | `tuple`   | `macro`   | `derives`  |               |                |                |
|   8   | `while`          | `f32`             | `decimal` | `import`  | `impl`     |               |                |                |
|   9   | `for`            | `f64`             | `number`  | `const`   | `const`    |               |                |                |
|   10  | `try`            | `f80`             |           | `requires`| `union`    |               |                |                |
|   11  | `catch`          | `f128`            | `bitset`  |           |            |               |                |                |
|   12  | `finally`        | `void`            | `erased`  |           |            |               |                |                |
|   13  | `break`          | `bool`            | `question`|           |            |               |                |                |
|   14  | `continue`       | `char`            |           |           |            |               |                |                |
|   15  | `assert`         |                   |           |           |            |               |                |                |

| **N** | **Prefix**  | **Postfix** | **Unary** | **Logical** | **Bitwise** | **Assignment** | **Arithmetic** | **Binary**  |
|-------|-------------|-------------|-----------|-------------|-------------|----------------|----------------|-------------|
| 1     | `l`? `+`    | `r`? `++`   | `..`      | `!`         | `~`         | `=`            | `+`            | `as`        |
| 2     | `l`? `-`    | `r`? `--`   | `..=`     | `&&`        | `&`         | `+=`           | `-`            | `in`        |
| 3     | `l`? `~`    | `r`? `?`    |           | `\|\|`      | `\|`        | `-=`           | `*`            | `derives`   |
| 4     | `l`? `!`    | `r`? `...`  |           | `==`        | `^`         | `*=`           | `/`            | `impl`      |
| 5     | `l`? `++`   | `r`? `?.`   |           | `===`       | `<<`        | `/=`           | `%`            | `::`        |
| 6     | `l`? `--`   |             |           | `!=`        | `>>`        | `%=`           | `,`            | `.`         |
| 7     | `l`? `&`    |             |           | `>`         |             | `&=`           | `@`            | `.*`        |
| 8     | `l`? `*`    |             |           | `<`         |             | `\|=`          | `**`           | `->`  ???   |
| 9     | `delete`    |             |           | `>=`        |             | `^=`           |                | `->*`       | (FIXME: add this to the ebnf)
| 10    | `await`     |             |           | `<=`        |             | `<<=`          |                |             |
| 11    | `async`     |             |           |             |             | `>>=`          |                |             |
| 12    | `panic`     |             |           |             |             | `**=`          |                |             |
| 13    | `yield`     |             |           |             |             | `@=`           |                |             |
| 14    | `thread`    |             |           |             |             |                |                |             |
| 15    | `sizeof`    |             |           |             |             |                |                |             |
| 16    | `alignof`   |             |           |             |             |                |                |             |
| 17    | `typeof`    |             |           |             |             |                |                |             |
| 18    | `const`     |             |           |             |             |                |                |             |
| 19    | `unsafe`    |             |           |             |             |                |                |             |
 

| **Feature**     | **Struct** | **Class** | **Enum**  | **Union** | **Interface** |
|-----------------|------------|-----------|-----------|-----------|---------------|
| Fields          | ✅ Yes     | ✅ Yes     | ❌ No     | ✅ Yes    | ✅ Yes        |
| Methods         | ❌ No      | ✅ Yes     | ❌ No     | ✅ Yes    | ✅ Yes        |
| Type Safety     | ✅ Strong  | ✅ Strong  | ✅ Weak   | ✅ Weak   | ✅ Strong     |
| Mutability      | ✅ Yes     | ✅ Yes     | ❌ No     | ✅ Yes    | ❌ No         |
| Matchable       | ✅ Yes     | ✅ Yes     | ✅ Yes    | ✅ Yes    | ❌ No         |
| Inheritance     | ❌ No      | ✅ Yes     | ❌ No     | ❌ No     | ✅ Yes        |
| Operators       | ✅ Yes     | ✅ Yes     | ❌ No     | ❌ No     | ✅ Yes        |
| Default Values  | ✅ Yes     | ✅ Yes     | ✅ Yes    | ✅ Yes    | ❌ No         |
| Overhead        | ❌ No      | ✅ Yes     | ❌ No     | ✅ Yes    | ❌ No         |

### **Control Flow**
- `if`
- `else`
- `for`
- `while`
- `unless`
- `break`
- `continue`
- `switch`
- `case`
- `default`
- `match`
- `return`

### **Exception Handling**
- `try`
- `catch`
- `finally`
- `panic`
- `assert`

### **Data Types**
- `bool`
- `void`
- `null`
- `true`
- `false`
- `u8`, `u16`, `u32`, `u64`, `u128`, `u256`
- `i8`, `i16`, `i32`, `i64`, `i128`, `i256`
- `usize`
- `isize`
- `f32`, `f64`, `f80`, `f128`
- `type`

### **Object-Oriented Programming**
- `class`
- `interface`
- `struct`
- `enum`
- `self`
- `extends`
- `impl`
- `derives`
- `override`
- `final`
- `delete`

### **Access Modifiers**
- `pub`
- `priv`
- `prot`
- `intl`

### **Function-Related**
- `op`
- `fn`
- `async`
- `await`
- `yield`
- `noreturn`
- `inline`
- `static`
- `thread`

### **Memory and Low-Level**
- `sizeof`
- `alignof`
- `typeof`
- `unsafe`
- `ffi`

### **Variables and Scope**
- `var`
- `const`

### **Modules and Imports**
- `module`
- `import`

### **Operators and Keywords**
- `as`
- `in`
- `is`
- `where`

### **Error and Debugging**
- `test`
- `requires`

### **Miscellaneous**
- `macro`
- `eval`