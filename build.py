# this file does 2 really simple things:
# 1. finds driver/helix.hlx and compiles it with all the flags
# 2. finds all the .hlx files and updates the compile_commands.json file
# the command used to compile is: build/release/arm64-llvm-macosx/bin/helix

import os
from pathlib import Path
import subprocess
import json
import logging
from typing import List
from rich.logging import RichHandler

import platform
import sys

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

# Setup rich-enhanced logging
logging.basicConfig(
    level=logging.INFO,
    format="%(message)s",
    handlers=[RichHandler(rich_tracebacks=True)]
)
log = logging.getLogger("helix-builder")

COMPILER_PATH = Path("build/release/arm64-llvm-macosx/bin/helix")
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

        # output dir is build/target_triple/debug or release/bin/...
        self.output_dir = Path("build", target_triple, "debug" if self.debug else "release")
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
        if self.binary is None:
            out = self.file.stem
        else:
            out = self.binary

        self.cmd = [
            str(self.compiler),
            str(self.file),
            f"-o{self.output_dir}/bin/{out}"
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
Builder("driver/bin/helix.hlx", "helix")                                       \
    .add_include_dir(Path("."))                                                \

# the helix code formatter
Builder("driver/bin/fmt.hlx", "helix-fmt")                                     \
    .add_include_dir(Path("."))                                                \
    
# the helix ide client for lsp support
Builder("driver/bin/analyzer.hlx", "helix-analyzer")                           \
    .add_include_dir(Path("."))                                                \
    
# the helix linker
Builder("driver/bin/ld.hlx", "helix-ld")                                       \
    .add_include_dir(Path("."))                                                \
    
# the helix package manager
Builder("driver/bin/vial.hlx", "vial")                                         \
    .add_include_dir(Path("."))                                                \

# ----------------------------------- END OF COMPILER COMMANDS ----------------------------------- #

def update_compile_commands():
    if not Path("compile_commands.json").exists():
        # Create an empty compile_commands.json file
        with open("compile_commands.json", "w") as f:
            json.dump([], f)
    with open("compile_commands.json", "r") as f:
        compile_commands = json.load(f)

    new_compile_commands: list[dict] = []

    # also index all the .hlx files in the current directory and its subs and assume the same
    # flags as the helix.hlx file

    if len(Builder.builders) == 0:
        log.error("No builders found. Please add a builder.")
        return
    
    """
    At some point in the future instead of assuming the same flags as the helix.hlx file
    we look at the includes and then the .hlx files in the includes would follow the same
    same flags as its builder
    """

    builder0 = Builder.builders[0]
    builder0.build_compile_commands()

    all_the_hlx_files = [
        # exclude the build directory
        file for file in Path(".").rglob("*.hlx")
        if "build" not in file.parts and
           "lib-helix" not in file.parts
    ]

    all_the_builders_files = [
        builder0.file for builder0 in Builder.builders
    ]

    appended_files = [
        file for file in all_the_hlx_files if file not in all_the_builders_files
    ]

    for file in appended_files:
        new_compile_commands.append({
            "directory": str(os.getcwd()),
            "command": builder0.cmd[3:],
            "file": str(Path(file).absolute())
        })

    for builder in Builder.builders:
        command = {
            "directory": str(os.getcwd()),
            "command": builder.cmd[3:],
            "file": str(Path(builder.file).absolute())
        }
        new_compile_commands.append(command)

    # replace all duplicates with the new ones
    # while keeping the old ones

    with open("compile_commands.json", "w") as f:
        json.dump(new_compile_commands, f, indent=4)
        log.info("Updated compile_commands.json with new compile commands.")
        log.info("Added new compile commands to compile_commands.json.")


def main():
    update_compile_commands()
    
    
    for builder in Builder.builders:
        builder.compile()
    
    log.info("All builders compiled successfully.")


if __name__ == "__main__":
    main()