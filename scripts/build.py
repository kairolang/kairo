# this file does 2 really simple things:
# 1. finds driver/helix.hlx and compiles it with all the flags
# 2. finds all the .hlx files and updates the compile_commands.json file
# the command used to compile is: build/release/arm64-llvm-macosx/bin/

# to make an alias to helix use:
# New-Alias -Name helix -Value .\build\release\x64-msvc-windows\bin\helix.exe

import os
from pathlib import Path
import subprocess
import json
import logging
from typing import List
from rich.logging import RichHandler
from concurrent.futures import ThreadPoolExecutor

import platform
import sys

# Setup rich-enhanced logging
logging.basicConfig(
    level=logging.INFO,
    format="%(message)s",
    handlers=[RichHandler(rich_tracebacks=True)]
)
log = logging.getLogger("helix-builder")

arch = platform.machine()
system = platform.system().lower()

if system == "darwin":
    system = "macos"
elif system == "windows":
    system = "windows"
elif system == "linux":
    system = "linux"

if arch == "AMD64":
    arch = "x86_64"
elif arch == "x86":
    arch = "i686"
elif arch == "aarch64":
    arch = "arm64"

if system == 'windows':
    abi = 'msvc'
else:
    abi = 'gnu'

target_triple = f"{arch}-{system}-{abi}"

MSVC_FLAGS = [
    "cl.exe", "/nologo", "/std:c++latest", "/MT", "/w",
    "/Isource", "/Ilib-helix\\core\\include", "/Ilib-helix\\core", "/Ilibs",
    "/EHsc", "/DNDEBUG"
]

CLANG_FLAGS = [
    "clang++", "-std=c++23", "-O3", "-w",
    "-Isource", "-Ilib-helix/core/include", "-Ilib-helix/core", "-Ilibs",
    "-DNDEBUG"
]

ALL_CPP_EXTS = {".c", ".cc", ".cpp", ".cxx", ".h", ".hh", ".hpp"}

COMPILER_PATH = Path("build/release/arm64-llvm-macosx/bin/helix") if system == "macos" else \
               Path("build/release/x86_64-linux-gnu/bin/helix") if system == "linux" else \
               Path("build/release/x64-windows-msvc/bin/helix.exe") if system == "windows" else \
               Path("build/release/x86_64-linux-gnu/bin/helix")
if not COMPILER_PATH.exists():
    log.error(f"Compiler not found at {COMPILER_PATH}. Please build the"
               "compiler first.")
    sys.exit(1)

class Builder:
    builders: list["Builder"] = []

    def __init__(self, compile: Path, target: str = None):
        self.file = compile
        self.binary = target
        self.compiler = COMPILER_PATH
        self.cxx_flags: list[str] = []
        self.includes: list[Path] = []
        self.links: list[Path] = []
        self.link_libs: list[str] = []
        self.emit_ir = False
        self.emit_ast = False
        self.verbose = False
        self.debug = False
        self.before_build: function = None
        self.after_build: function = None
        self.cmd: list[str] = []

        for arg in sys.argv[1:]:
            if arg == "--debug":
                self.debug = True
            elif arg == "--verbose":
                self.verbose = True
            elif arg == "--emit-ir":
                self.emit_ir = True
            elif arg == "--emit-ast":
                self.emit_ast = True

        if self.binary is None:
            out = self.file.stem
        else:
            out = self.binary


        # output dir is build/target_triple/debug or release/bin/...
        self.output_dir = Path("build", target_triple, "debug" if self.debug else "release")
        self.output: str = f"-o{self.output_dir}/bin/{out}"
        Path(self.output_dir, "bin").mkdir(parents=True, exist_ok=True)
        Builder.builders.append(self)

    def add_cxx_flag(self, flag: str) -> "Builder":
        """Add a C++ flag to the compiler."""
        self.cxx_flags.append(flag)
        log.debug(f"Added C++ flag: {flag}")
        return self

    def add_include_dir(self, path: Path) -> "Builder":
        """Add an include directory to the compiler."""
        self.includes.append(path.absolute())
        log.debug(f"Added include directory: {path}")
        return self

    def add_link_dir(self, path: Path) -> "Builder":
        """Add a link directory to the compiler."""
        self.links.append(path.absolute())
        log.debug(f"Added link directory: {path}")
        return self
    
    def add_link_lib(self, lib: str) -> "Builder":
        """Add a link library to the compiler."""
        self.link_libs.append(lib)
        log.debug(f"Added link library: {lib}")
        return self
    
    def toggle_emit_ir(self) -> "Builder":
        """Toggle IR emission."""
        self.emit_ir = not self.emit_ir
        log.debug(f"Emit IR: {self.emit_ir}")
        return self
    
    def toggle_emit_ast(self) -> "Builder":
        """Toggle AST emission."""
        self.emit_ast = not self.emit_ast
        log.debug(f"Emit AST: {self.emit_ast}")
        return self
    
    def toggle_verbose(self) -> "Builder":
        """Toggle verbose mode."""
        self.verbose = not self.verbose
        log.debug(f"Verbose: {self.verbose}")
        return self
    
    def build_compile_commands(self) -> "Builder":
        """Build the compile commands for the compile_commands.json file."""

        self.cmd = [
            str(self.compiler),
            str(self.file),
            self.output
        ]
        
        if self.verbose:
            self.cmd.append("--verbose")
        if self.debug:
            self.cmd.append("--debug")
        if self.emit_ir:
            self.cmd.append("-emit-ir")
        if self.emit_ast:
            self.cmd.append("-emit-ast")
        
        for include in self.includes:
            self.cmd.append(f"-I{include}")
        for link in self.links:
            self.cmd.append(f"-L{link}")
        for lib in self.link_libs:
            self.cmd.append(f"-l{lib}")


        if len(self.cxx_flags) > 0:
            self.cmd.append("--")

            for flag in self.cxx_flags:
                self.cmd.append(flag)

        return self
    
    def compile(self):
        """Compile the target file."""
        # the out is the filename without the extension or path of the file if
        # target is not set

        self.build_compile_commands()
        
        if self.before_build:
            self.before_build(self)
    
        log.info(f"Compiling {self.file} with command: {' '.join(self.cmd)}")
        
        try:
            subprocess.run(self.cmd, check=True)
            log.info(f"Compiled {self.file} successfully.")

            if self.after_build:
                self.after_build(self)
        
        except subprocess.CalledProcessError as e:
            log.error(f"Compilation failed: {e}")

# ---------------------------------- START OF COMPILER COMMANDS ---------------------------------- #

# the helix compiler
Builder("toolchain/driver/bin/helix.hlx", "helix")                             \
    .add_include_dir(Path("."))                                                \
    .add_include_dir(Path(".") / "toolchain")                                  \

# the helix code formatter
Builder("toolchain/driver/bin/fmt.hlx", "helix-fmt")                           \
    .add_include_dir(Path("."))                                                \
    .add_include_dir(Path(".") / "toolchain")                                  \
    
# the helix ide client for lsp support
Builder("toolchain/driver/bin/analyzer.hlx", "helix-analyzer")                 \
    .add_include_dir(Path("."))                                                \
    .add_include_dir(Path(".") / "toolchain")                                  \
    
# the helix linker
Builder("toolchain/driver/bin/ld.hlx", "helix-ld")                             \
    .add_include_dir(Path("."))                                                \
    .add_include_dir(Path(".") / "toolchain")                                  \
    
# the helix package manager
Builder("toolchain/driver/bin/vial.hlx", "vial")                               \
    .add_include_dir(Path("."))                                                \
    .add_include_dir(Path(".") / "toolchain")                                  \

# ----------------------------------- END OF COMPILER COMMANDS ----------------------------------- #

def update_compile_commands():
    cwd = Path.cwd()
    cwd_str = str(cwd)

    builder0 = Builder.builders[0]
    builder0.build_compile_commands()

    skip_dirs = {"build", "libs", "private"}
    new_compile_commands = []

    # Collect files in one pass
    all_hlx = []
    for path in cwd.rglob("*"):
        if any(skip in path.parts for skip in skip_dirs):
            continue
        if path.suffix.lower() in ALL_CPP_EXTS:
            rel = path.relative_to(cwd)
            args = MSVC_FLAGS.copy() if system == "windows" else CLANG_FLAGS.copy()
            new_compile_commands.append({
                "directory": cwd_str,
                "arguments": args + [str(rel)],
                "file": str(rel)
            })
        elif path.suffix.lower() == ".hlx":
            all_hlx.append(path)

    builder_files_set = {b.file for b in Builder.builders}
    appended_files = [f for f in all_hlx if f not in builder_files_set]

    # Add hlx files
    for file in appended_files:
        new_compile_commands.append({
            "directory": cwd_str,
            "arguments": builder0.cmd[3:],
            "file": str(file.resolve())
        })

    # Add builder files
    for builder in Builder.builders:
        new_compile_commands.append({
            "directory": cwd_str,
            "arguments": builder.cmd[3:],
            "file": str(Path(builder.file).resolve())
        })

    with open("compile_commands.json", "w") as f:
        json.dump(new_compile_commands, f, indent=2)


def test(test_path: Path):
    # we still use the first builders flags with the test file but theres one diff here we
    # copy the test file to a temp location (build/.shared/tests/) and then compile it there
    # but beofre the coping we need to make sure the file contains a fn Test() -> i32 { ... }
    # if not, log an error and return
    
    found_test_fn = False
    in_multi_line_comment = 0

    with open(test_path, "r") as f:
        for line in f.readlines():
            i = 0
            stripped_line = ""
            while i < len(line):
                if in_multi_line_comment > 0:
                    if line.startswith("/*", i):
                        in_multi_line_comment += 1
                        i += 2
                        continue
                    elif line.startswith("*/", i):
                        in_multi_line_comment -= 1
                        i += 2
                        continue
                    else:
                        i += 1
                        continue

                if line.startswith("//", i):
                    # rest of line is comment
                    break
                elif line.startswith("/*", i):
                    in_multi_line_comment += 1
                    i += 2
                    continue
                else:
                    stripped_line += line[i]
                    i += 1

            if "fn Test() -> i32" in stripped_line:
                found_test_fn = True
                break
        
    if not found_test_fn:
        log.error("Test file must contain a function `fn Test() -> i32 { ... }`")
        return
    
    temp_test_dir = Path("build/.shared/tests")
    temp_test_dir.mkdir(parents=True, exist_ok=True)
    temp_test_file = temp_test_dir / test_path.name
    
    with open(test_path, "r") as src, open(temp_test_file, "w") as dst:
        dst.write(src.read())
        # we also need to add a main function to call the Test function
        dst.write("\nfn main() -> i32 {\n")
        dst.write("    return Test();\n")
        dst.write("}\n")
        log.info(f"Copied test file to {temp_test_file}")

    test_builder = Builder(temp_test_file, "test")
    test_builder.includes = Builder.builders[0].includes
    test_builder.links = Builder.builders[0].links
    test_builder.link_libs = Builder.builders[0].link_libs
    test_builder.cxx_flags = Builder.builders[0].cxx_flags
    test_builder.debug = True
    # we compile the file to build/.gens/test_run
    test_output_dir = Path("build/.gens/")
    test_output_dir.mkdir(parents=True, exist_ok=True)
    test_builder.output = f"-o{test_output_dir}/test_run"

    test_builder.build_compile_commands()
    test_builder.compile()
    log.info(f"Running test binary {test_output_dir}/test_run")
    
    # we run the file in the cur shell to make sure all stdout and errr is shown
    print("-" * os.get_terminal_size().columns)
    try:
        # print a horizinal line full width of the terminal before running the test
        result = subprocess.run([str(test_output_dir / "test_run")], check=True)
        log.info(f"Test executed successfully with exit code {result.returncode}")
    except subprocess.CalledProcessError as e:
        log.error(f"Test execution failed: {e}")
    print("-" * os.get_terminal_size().columns)

    return

def main():
    update_compile_commands()

    if "--update-index" in sys.argv:
        return
    
    test_file = None
    for arg in sys.argv:
        if arg.endswith(".hlx"):
            test_file = arg
            break

    test_path = Path(test_file)
    if not test_path.exists():
        log.error(f"Test file {test_file} does not exist.")
        return
    else:
        return test(test_path)
    
    with ThreadPoolExecutor() as executor:
        futures = [executor.submit(builder.compile) for builder in Builder.builders]
    
        for future in futures:
            try:
                future.result()
            except Exception as e:
                log.error(f"Compilation failed: {e}")
    
    log.info("All builders compiled successfully.")


if __name__ == "__main__":
    main()