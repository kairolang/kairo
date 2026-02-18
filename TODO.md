# Todo list of all the things remaining to be done in the short term. (high to low priority)

- [x] Parse TurboFish syntax (temporary until the symbol table is implemented)
- [x] Parse and codegen reference and pointer types along with nullability
- [x] Parse and codegen function pointers
- [x] Parse Tuple types and codegen them
- [ ] Add support for packing and unpacking functions and destructuring
- [ ] Parse simple macros and invocations
- [ ] Parse eval if statements
- [x] Get CXIR compile messages to convert to kairo errors
- [x] Parse basic kairo imports (no symbol resolution)
- [ ] Codegen C++ headers to allow C++ to call kairo code
- [ ] Parse and codegen catch blocks with no catch type
- [ ] Make test syntax work for definitions and usages
- [ ] Make classes immutable by default
- [x] Get f-strings working
- [x] Convert clang errors into the kairo error msg format.
- [ ] Convert gcc errors into the kairo error msg format.
- [x] Convert msvc errors into the kairo error msg format.
- [ ] Fix ast error messages, where the message tells a fix to also add a quick fix to the error
- [x] Add support for global scopes in the parser


# TODO remaining until standard library can be implemented:
- [x] Codegen the missing codgen functions (lambdas, maps, sets, and a couple of others)
- [x] Codegen Interfaces
- [ ] Parse and codegen `extend` syntax for generic specializations
- [ ] Parse and codegen `...` variadic argument syntax
- [ ] Parse and codegen `#` compiler directives
- [ ] Codegen Modifiers and Attributes (partly done - only functions is done)
- [ ] Make scope paths with generics work
- [ ] Make panic and panic unwinding work
- [ ] make operator $question work
- [ ] make the core lib auto import by default
- [x] ObjInitializer doesnt work for some reason
- [ ] note: replace 'default' with 'delete'
- [ ] change lexer to not work with any op and stop after the first match
- [ ] make structs work with 'with'
- [ ] F-strings are broken in 2 ways, 1. they dont work if theres no format specifier inside an fstring like: f"hello" (fails but should work) 2. f"hello {"world"}" works but if theres a bracket inside the fstring it fails: f"hello {"workd {"}}"}" (fails but should work since the string inside isnt a fstring)


### **1. Parse and Codegen Function Pointers**
**Description:**
Implement parsing and code generation for function pointers. Ensure proper handling of type declarations, nullability, and invocation semantics.

**Acceptance Criteria:**
- Syntax for declaring and using function pointers is supported.
- Proper code generation for function pointers in C++ backend.
- Nullability checks are implemented.

---

### **2. Add Support for Packing and Unpacking Functions and Destructuring**
**Description:**
Introduce support for packing and unpacking arguments in functions. Enable destructuring to simplify working with tuple-like types or objects.

**Acceptance Criteria:**
- Support `pack` and `unpack` syntax for functions.
- Implement destructuring for tuples and structured bindings.
- Ensure clear error handling for misuse of syntax.

---

### **3. Parse Simple Macros and Invocations**
**Description:**
Add functionality to parse simple macros and their invocations. This includes basic macro substitution and handling preprocessor-like features.

**Acceptance Criteria:**
- Syntax for defining macros is supported.
- Macros can be invoked within the code.
- Clear error messages for unsupported or malformed macros.

---

### **4. Parse `eval` If Statements**
**Description:**
Implement parsing for `eval` conditional statements to allow runtime-evaluated conditions within the code.

**Acceptance Criteria:**
- Syntax for `eval if` is supported.
- Code generation handles runtime evaluation seamlessly.
- Comprehensive tests for valid and invalid use cases.

---

### **5. Get CXIR Compile Messages to Convert to Kairo Errors**
**Description:**
Adapt CXIR compile messages into the Kairo error format for consistency and clarity in reporting.

**Acceptance Criteria:**
- CXIR compile errors are converted into Kairo-style error messages.
- Ensure proper formatting and accurate mapping of error types.

---

### **6. Codegen C++ Headers to Allow C++ to Call Kairo Code**
**Description:**
Generate C++ header files for Kairo modules, enabling seamless interoperation where C++ code can call Kairo functions.

**Acceptance Criteria:**
- C++ headers are correctly generated with all relevant Kairo function prototypes.
- Ensure compatibility with various C++ compilers.

---

### **7. Parse and Codegen Catch Blocks with No Catch Type**
**Description:**
Support parsing and code generation for `catch` blocks that handle any exception without specifying a type.

**Acceptance Criteria:**
- Syntax for `catch` without type is supported.
- Generated C++ code handles the behavior correctly.
- Proper handling of edge cases and errors.

---

### **8. Make Test Syntax Work for Definitions and Usages**
**Description:**
Update test framework to support syntax for both defining tests and invoking them in code.

**Acceptance Criteria:**
- Test definitions and invocations are supported.
- Clear error messages for invalid test syntax.

---

### **9. Make Classes Immutable by Default**
**Description:**
Change the default behavior of classes to be immutable, ensuring explicit syntax for mutable classes or fields.

**Acceptance Criteria:**
- All classes are immutable unless explicitly marked.
- Compiler enforces immutability rules.

---

### **10. Convert GCC Errors into the Kairo Error Msg Format**
**Description:**
Transform GCC errors into the Kairo error message format for a consistent user experience across compilers.

**Acceptance Criteria:**
- GCC errors are correctly converted.
- Ensure proper mapping of GCC-specific errors to Kairo equivalents.

---

### **11. Fix AST Error Messages with Quick Fix Suggestions**
**Description:**
Improve AST error messages by including actionable quick fixes alongside error explanations.

**Acceptance Criteria:**
- Error messages suggest fixes when applicable.
- Comprehensive coverage for common AST errors.

---

### **12. Add Panic Unwinding Support**
**Description:**
Implement support for panic unwinding to manage error recovery and cleanup during runtime exceptions.

**Acceptance Criteria:**
- Panic unwinding works seamlessly with Kairo code.
- Tests for error handling and resource cleanup during unwinding.

---

### **13. Parse and Extend Support for Generic Specializations**
**Description:**
Extend parsing and code generation to support generic specializations for types and functions.

**Acceptance Criteria:**
- Syntax for generic specializations is supported.
- Code generation handles specializations correctly.

---

### **14. Codegen Missing Functions: Lambdas, Maps, Sets**
**Description:**
Implement code generation for lambdas, maps, sets, and any other missing structures in the current system.

**Acceptance Criteria:**
- All missing constructs are supported in codegen.
- Tests for correctness and edge cases.

---

### **15. Codegen Interfaces**
**Description:**
Add support for code generation of interfaces, ensuring proper virtual function handling in the C++ backend.

**Acceptance Criteria:**
- Interfaces are correctly codegen-ed.
- Virtual functions are properly handled.

---

### **16. Parse and Codegen `extend` Syntax**
**Description:**
Implement parsing and code generation for the `extend` syntax, allowing Kairo types to extend their functionality.

**Acceptance Criteria:**
- `extend` syntax is fully supported.
- Proper code generation for extensions.

---

### **17. Parse and Codegen `...` Variadic Argument Syntax**
**Description:**
Add support for variadic arguments using the `...` syntax in functions and method definitions.

**Acceptance Criteria:**
- Variadic argument syntax is supported.
- Tests for usage and misuse of the syntax.

---

### **18. Parse and Codegen `#` Compiler Directives**
**Description:**
Implement parsing and handling of `#` compiler directives for advanced compile-time functionality.

**Acceptance Criteria:**
- Directives are parsed and processed correctly.
- Errors for unsupported or invalid directives.

---

### **19. Codegen Modifiers and Attributes**
**Description:**
Add support for code generation of modifiers and attributes to customize behavior or metadata for code constructs.

**Acceptance Criteria:**
- All relevant modifiers and attributes are supported.
- Tests for various use cases and edge cases.



# Completed:
### Parser:
- [x] Parse types
- [x] Parse functions
- [x] Parse structs
- [x] Parse enums
- [x] Parse constants
- [x] Parse variables
- [x] Parse Operator Overloads
- [x] Parse Interfaces

# draft: **Merging Pointers and References**
### Rule Set (safe pointers):
- **`*i32`:**
  - Behaves like a reference: accessed without explicit dereferencing.
  - Can be uninitialized initially but must be initialized before usage. (checked at compile-time)
  - Must always point to a valid memory address. (enforced by not being allowed to set a custom location to point to)
  - Cannot be set to `&null`.
  - Internally auto-dereferences during code generation.

```rs
let a: i32 = 123;
let a_ptr: *i32 = &a;

print(a_ptr); // prints 123
a_ptr + 2;    // a_ptr = 125
```

- **`*i32?`:**
  - Similar to a reference: accessed without explicit dereferencing.
  - Can be uninitialized initially but must be initialized before usage. (checked at compile-time)
  - Can point to `&null`, and this can be checked using `... != &null`. (compile-time warning if not checked for null)
  - Must always point to a valid memory address. (enforced by not being allowed to set a custom location to point to)
  - Internally auto-dereferences during code generation.

```rs
let a: i32 = 123;
let a_ptr: *i32? = &null;

a_ptr = &a; // a_ptr = 123

if a_ptr != &null {
    print(a_ptr); // prints 123
    a_ptr + 2;    // a_ptr = 125
}
```

### Rule Set (unsafe pointers):
- **`unsafe *i32`:**
  - Requires explicit dereferencing for access.
  - Must be initialized before usage. (checked at compile-time)
  - Can be set to `&null` and does not need to point to a valid memory address.

```rs
let a: i32 = 123;
let a_ptr: unsafe *i32 = 0xAB12 as unsafe *i32; // a_ptr points to 0xAB12

print(*a_ptr); // if 0xAB12 is uninitialized then segfault or undefined behavior, else reads data in 0xAB12

a_ptr = &a; // reassign to a address
```

- **`unsafe *i32?`:**
  - Requires explicit dereferencing for access.
  - Doesn’t need to be initialized by the time of usage.
  - Can be set to `&null` and does not need to point to a valid memory address.

```rs
let a: i32 = 123;
let a_ptr: unsafe *i32?; // a_ptr points to 0xAB12

a_ptr = 0xAB12 as *i32;

print(*a_ptr); // if 0xAB12 is uninitialized then segfault or undefined behavior, else reads data in 0xAB12

a_ptr = &a; // reassign to a address
```

- **`&i32?` | `&i32`:**
  - Should be disallowed completely.
  - If a user needs a version of `*i32` that cannot be uninitialized, they should use `reference<i32>` instead.