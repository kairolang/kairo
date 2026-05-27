# Kairo Programming Language

<div align="center">
  <img src="Assets/kairo-logo.svg" alt="Kairo Programming Language Logo" width="60%">
</div>

---

Kairo is a **statically typed compiled language**, built for systems programming and high-performance applications. Designed with native bi-directional C++ interoperability in mind. Kairo aims to combine the power and control of low-level languages with the safety and clarity of high-level design.

### The goals of Kairo:

- Safe, and productive programming language.
- Allow for low-level programming with fine-grained control.
- Native bidirectional C and C++ interoperability interoperability with C and C++ along with other native languages.
- Include a portable, well-structured standard library.
- Encourage clear, maintainable, and reviewable code through strong, expressive semantics.
- An alternative to C, C++ or work alongside them.
- No runtime, no garbage collector, no hidden costs - every cost is documented and compiler stated, no surprises.

### Current Status:

The **Stage 0 compiler** (written in C++) is functional and can compile Kairo, you can download it from the [release page](https://github.com/kairolang/kairo/releases), currently very unstable, and riddled with bugs. Development of the **Stage 1 compiler**, written in Kairo itself, is in progress.
> [!WARNING]
> [Documentation](https://www.kairolang.org/docs) is technically complete now matching, stage1 and what it can do once built, but the compiler is still in development and not ready for production use.
> Also, yes the docs are missing the language's core points, AMT, ownership model, and a few other key features, but they will be added soon, We are still finalizing them internally, before documenting them publicly. If you want to help, please reach out to us on [Discord](https://discord.gg/VHCnPccDc)

### Why Kairo?

##### Think of programming languages like making coffee.

- **C and C++** hands you all the ingredients and equipment, every knob and button live. No recipe, no instructions. You'll have to learn and make something, what you make is on you.
- **Rust** provides you with all the ingredients, fancy equipment, and a precise recipe with every step measured. The coffee comes out reliably good, and the recipe catches mistakes before you brew.
- **Kairo** gives you ingredients, equipment, and recipes, and the kitchen is wired into the C and C++ kitchens next door. Borrow their beans and machines, and send finished coffee back through the same door.

### Design Rationale:

- We liked the simplicity of **Python's** syntax but wanted more.
- We wanted the performance and control of **C and C++**.
- We admired **Rust's** safety features but, at times, found them cumbersome.
- We liked **Rust's** Meta-programming and Trait system.
- We liked **Zig's** approach to interoperability.
- We wanted a powerful module system.
- We wanted a robust standard library.
- We wanted a language that would work drop-in with any existing C or C++ codebases.
- We wanted all; *without* compromising on any front.
- So we created **Kairo**.

Kairo is built to slot directly into C **and** C++ ecosystems, offering a fresh syntax and features, without abandoning decades of code.

### Getting Started:

**Download a release:** grab a prebuilt binary from the [releases page](https://github.com/kairolang/kairo/releases).

**Build from source:** see [BUILD.md](BUILD.md) - covers the quick install script, manual setup, PATH configuration, the VSCode extension, and debugging.

**Code reference:** since the docs are still catching up, the [Compiler directory](https://github.com/kairolang/kairo/tree/canary/kairo-0.1.1%2Bbc.251007/Compiler) has working Stage 0 examples.

### License:

Kairo is licensed under the Attribution 4.0 International License. See the [LICENSE](https://github.com/kairolang/kairo/blob/main/license) for more details.

### Acknowledgements:

We want to thank all our contributors pushing Kairo forward.

### [AI Usage Disclosure](https://www.kairolang.org/blog/how-ai-is-used-in-kairo/)

TLDR: lang design, compiler, and architecture are 100% human. AI is used as a debugging assistant (second pair of eyes, not code author), polishing raw technical docs into readable prose, building the website (no one on the team is a web dev), git commit messages (laziness), doc comments (laziness), and the Stage 0 LSP/VSCode extension scaffolding. No AI-generated code in the compiler and language design stage1 or stage0.

<div align="center">
  <a href="https://github.com/kairolang/kairo/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=kairolang/kairo">
</a>
</div>