/// --- The Kairo Project -------------------------------------------------- ///
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///
//                                                                                                //
// this is the drop in replacement for the entire Kairo compiler, this will be used when          //
// rewriting the compiler in kairo itself (self-hosting), the reason this is the entry point is   //
// kairo the compiler can now work with the c++ interop modules rather then having to compile     //
// only kairo files into c++ headers then include them, instead we can now just use bi-directional//
// ffi to include c++ headers and use them in kairo code.                                         //
//                                                                                                //
//====----------------------------------------------------------------------------------------====//


/*
using the new toolchain the entire process can happen like this:
*/
fn foo() -> i32? {
    panic "this is a panic";
}

fn abc() -> i32 {
    var x = ["hello", "world"];

    // fails to codegen correctly since the `as` requires a primary expr on the right
    return x[0].length() as i32;
    // the really annoying thing is the error message is not helpful at all, it just says
    // "function `length` not found." which is not true. the reason is because the c++ codegen looks
    // like this: `kairo::std::as<i32>(x[0]).length()`, which is not correct and the reason it fails.
    //
    // couple of notes about kairo:
    // - the language is still in development and is not stable yet.
    // - the language right now impl a c++ backend, and the self-hosted compiler would initially also
    //   have a c++ backend. but that would be migrated to a llvm backend later on. (the c++ backend
    //   is just a temporary solution, since llvm is really hard to work with and the c++ backend is
    //   much easier to work with - for now)

    // this is the fix: (looks bad but it's the only way to fix it right now)
    return (x[0].length()) as i32;

    // this is one of many little things that are very finicky in the language but it will be fixed
    // with the self-hosted compiler.
    //
    // the current compiler is very limited in what it can do, but it's a start and does work for the
    // most part, the self-hosted compiler will be able to do much more and be much more flexible.
}

fn <N: std::size_t> kairo_compiler(std::array::<std::string, N> args) -> i32 {
    var invoke      = InvocationManager(args, true);
    var compile     = CompilationUnit(invoke);
    var diag_handle = PrettyDiagnosticHandler();

    // frontend processors
    compile.add_frontend_processor(Mem::Heap::<LexicalProcessor>());
    compile.add_frontend_processor(PreProcessor());
    compile.add_frontend_processor(ASTProcessor());

    // backend processors
    compile.add_backend_processor(CXIRGenerator());
    compile.add_backend_processor(ExecutableGenerator<OutputFormat::Executable>());

    // set diagnostics
    compile.set_diagnostic_handler(diag_handle);

    if (compile.execute() != CompilationUnit::Success) {
        switch (compile.exit_state) {
            case CompilationUnit::CompilerError:
                log("compiler internal error: ",
                    diag_handle
                        .get<CompilationUnit::CompilerError>()
                        .format() as string
                ); break;

            case CompilationUnit::CodeError:
                log(
                    "user code error: ",
                    diag_handle
                        .get<CompilationUnit::CodeError>()
                        .format() as string
                ); break;

            case CompilationUnit::UnrecoverableError:
                log(
                    "fatal error: ",
                    diag_handle
                        .get<CompilationUnit::UnrecoverableError>()
                        .format() as string
                ); break;

            case CompilationUnit::SystemError:
                log(
                    "sys call error: ",
                    diag_handle
                        .get<CompilationUnit::SystemError>()
                        .format() as string
                ); break;
        };

        diag_handle.panic(PrettyDiagnosticHandler::ColorMode::ON);
    }

    return 0;
}

/* other.k
```kairo

import main;

fn run_tests() {
    test main; // runs all tests defined in main.k
    test main["this is main.k"]; // runs the test with the given name
}

fn main() -> int {
    run_tests();

    // everything else

    return 0;
}

```
*/

