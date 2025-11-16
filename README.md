# Helix Programming Language

<div align="center">
  <img src="assets/helix-logo.svg" alt="Helix Programming Language Logo" width="60%">
</div>

---

Helix is a **statically typed  programming language**, built for systems programming and high-performance applications. Designed with interoperability in mind. Helix aims to combine the power and control of low-level languages with the safety and clarity of high-level design.

> [!NOTE]
> Helix is not associated with the [Helix-Editor](https://github.com/helix-editor/helix), we are in the process or rebranding, by Q1 2026 Helix-lang will be under a new name!

### The goals of Helix:

- Safe, and productive programming language.
- Allow for low-level programming with fine-grained control.
- Seamless interoperability with C and C++ along with other native languages.
- Include a portable, well-structured standard library.
- Encourage clear, maintainable, and reviewable code through strong, expressive semantics.
- An alternative to C, C++, and Rust or work alongside them.

### Current Status:
The **Stage 0 compiler** (written in C++) is functional and can compile Helix, you can downlaod it from the [release page](https://github.com/helixlang/helix-lang/releases), currently very unstable, and riddled with bugs. Development of the **Stage 1 compiler**, written in Helix itself, is in progress.
> [!WARNING]
>  Documentation is a work in progress, it doesn't refelct what Stage 0 can compile or do; since most of the code emaples are for stage 1's syntax - and yes, the discriptions are mostly written using AI (LLMs). We will be redoing it incrementally, until stage 1 is stable; We would appreciate any contributions, feedback, or suggestions you may have!
> 
> You can find the source on [GitHub](https://github.com/helixlang/helix-site), and the website is at [helix-lang.com](https://www.helix-lang.com). In the meantime if you'd want some reference of helix code that compiles on stage 0 take a look [here](https://github.com/helixlang/helix-lang/tree/canary/helix-0.1.1%2Bbc.251007/toolchain)

### Why Helix?

##### Think of programming languages like making coffee.
- **C and C++** give you the beans, grinder, and espresso machine; and all the ingredients, but you dont have any instructions on how to make it, you have all the freedom but no guidance.
- **Rust** gives you some ingredients and some fancy equipment, but you are forced to follow strict recipes and you don't have enough creative freedom do what you would like. You can't experiment with the recipes and create your own variations easily.
- **Helix** gives you all that you need, with clear recipes and instructions, but also allows you to experiment and make your own recipes, without any restrictions.

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
- So we created **Helix**.

Helix is built to slot directly into C **and** C++ ecosystems, offering a fresh syntax and features, without abandoning decades of code.

### Getting Started:
To get started with Helix, please refer to the [Installation Guide](https://www.helix-lang.com/install/) for code refrence (since the docs are inconsistent/incomplete) take a look [here](https://github.com/helixlang/helix-lang/tree/canary/helix-0.1.1%2Bbc.251007/toolchain).

### License:
Helix is licensed under the Attribution 4.0 International License. See the [LICENSE](https://github.com/helixlang/helix-lang/blob/main/license) for more details.

### Acknowledgements:
We want to thank all our contributors pushing Helix forward.

<div align="center">
  <a href="https://github.com/helixlang/helix-lang/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=helixlang/helix-lang">
</a>
</div>
