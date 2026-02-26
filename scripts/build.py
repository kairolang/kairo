# this file does 2 really simple things:
# 1. finds driver/kairo.kro and compiles it with all the flags
# 2. finds all the .kro files and updates the compile_commands.json file
# the command used to compile is: build/release/arm64-llvm-macosx/bin/

# to make an alias to kairo use:
# New-Alias -Name kairo -Value .\build\release\x64-msvc-windows\bin\kairo.exe

import os
from pathlib import Path
import subprocess
import json
import logging
import re
import tempfile
import shutil
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
log = logging.getLogger("kairo-builder")

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
    "/Isource", "/Ilib-kairo\\core\\include", "/Ilib-kairo\\core", "/Ilibs",
    "/EHsc", "/DNDEBUG"
]

CLANG_FLAGS = [
    "clang++", "-std=c++23", "-O3", "-w",
    "-Isource", "-Ilib-kairo/core/include", "-Ilib-kairo/core", "-Ilibs",
    "-DNDEBUG"
]

ALL_CPP_EXTS = {".c", ".cc", ".cpp", ".cxx", ".h", ".hh", ".hpp"}

# kairo can be run using $$ kairo <args>
COMPILER_PATH = "kairo"

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

# the kairo compiler
Builder("toolchain/Driver/Main/HBuild.kro", "kairo")                             \
    .add_include_dir(Path("."))                                                \
    .add_include_dir(Path(".") / "toolchain")                                  \

# the kairo code formatter
Builder("toolchain/Driver/Main/Kairo.kro", "kairo-fmt")                           \
    .add_include_dir(Path("."))                                                \
    .add_include_dir(Path(".") / "toolchain")                                  \
    
# the kairo ide client for lsp support
Builder("toolchain/Driver/Main/HFmt.kro", "kairo-analyzer")                 \
    .add_include_dir(Path("."))                                                \
    .add_include_dir(Path(".") / "toolchain")                                  \
    
# the kairo linker
Builder("toolchain/Driver/Main/HLd.kro", "kairo-ld")                             \
    .add_include_dir(Path("."))                                                \
    .add_include_dir(Path(".") / "toolchain")                                  \
    
# the kairo package manager
Builder("toolchain/Driver/Main/HLS.kro", "vial")                               \
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
        elif path.suffix.lower() == ".kro":
            all_hlx.append(path)

    builder_files_set = {b.file for b in Builder.builders}
    appended_files = [f for f in all_hlx if f not in builder_files_set]

    # Add kro files
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


def test(test_path: Path, performance: bool = False):
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
    test_builder.debug = False if performance else True
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

def extract_cpp_from_ir(file: str, line_range: str):
    """
    Calls Kairo to emit IR, strips boilerplate and colors, isolates the emitted C++
    for a given file and line range, then runs clang-format.
    """
    builder0 = Builder.builders[0]
    builder0.build_compile_commands()

    cmd = [builder0.compiler, file, "--emit-ir", "--verbose"]
    for inc in builder0.includes:
        cmd.append(f"-I{inc}")

    log.info(f"Running Kairo IR emission for {file}")
    result = subprocess.run(cmd, capture_output=True, text=True)
    output = result.stdout

    if not output.strip():
        log.error("No output received from Kairo compiler.")
        return

    # --- Step 1: Trim header preamble ---
    hdr_pat = re.compile(r"#define __KAIRO_CORE_CXX__.*?#endif", re.DOTALL)
    m = hdr_pat.search(output)
    if m:
        output = output[m.end():]

    # Trim the everything after the last #endif
    last_endif = output.rfind("#endif")
    if last_endif != -1:
        output = output[:last_endif + len("#endif")]

    # --- Step 2: Strip ANSI color codes ---
    ansi_escape = re.compile(r'\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])')
    output = ansi_escape.sub('', output)

    # --- Step 3: Build mapping from file -> list of lines ---
    file_lines: dict[str, list[str]] = {}
    current_file = None
    current_macro = None
    current_line = None
    in_guard_section = False

    for raw in output.splitlines():
        line = raw.strip()
        if not line:
            continue

        # Detect #define "<path>"
        if line.startswith("#define") and len(line.split()) == 3:
            _, macro, path_token = line.split(maxsplit=2)
            current_file = path_token.strip('"')
            current_macro = macro
            current_line = None
            in_guard_section = False
            if current_file not in file_lines:
                file_lines[current_file] = []
            continue

        # Handle #line directives
        if line.startswith("#line") and current_file:
            parts = line.split()
            try:
                ln = int(parts[1])
            except Exception:
                continue

            # If the #line belongs to this file macro, reset line base
            if len(parts) == 3 and parts[2] == current_macro:
                # Kairo emits 2 separate "#line 1" blocks for same file.
                # The second one (after the #define guards) is actual code.
                if in_guard_section:
                    # second #line 1 for same file: start fresh (real code)
                    file_lines[current_file] = []
                in_guard_section = True
                current_line = ln - 1
            elif len(parts) == 2:
                current_line = ln - 1
            continue

        # Skip preprocessor (non-guard) lines
        if line.startswith("#"):
            continue

        if current_file is None or current_line is None:
            continue

        # Extend file lines buffer
        lines = file_lines[current_file]
        while len(lines) <= current_line:
            lines.append("")
        # Append/merge same line if split across output chunks
        if lines[current_line]:
            lines[current_line] += "\n" + raw
        else:
            lines[current_line] = raw
        current_line += 1

    # --- Step 4: Match target file (absolute vs relative) ---
    found_file = None
    for path in file_lines:
        if path.endswith(file):
            found_file = path
            break

    if not found_file:
        log.error(f"No matching file section found for {file}")
        return

    lines = file_lines[found_file]
    log.info(f"Extracted {len(lines)} mapped lines for {found_file}")

    # --- Step 5: Parse line range (accept ':' or '-') ---
    if not line_range:
        all_lines = True
        line_range = f"1:{len(lines)}"
    if ":" in line_range:
        start_line, end_line = map(int, line_range.split(":"))
    elif "-" in line_range:
        start_line, end_line = map(int, line_range.split("-"))
    else:
        start_line = end_line = int(line_range)

    start_line = max(1, start_line)
    end_line = max(start_line, end_line)

    if start_line > len(lines):
        log.warning(f"Start line {start_line} beyond file end ({len(lines)}).")
        return

    isolated = lines[start_line - 1:end_line]
    isolated_code = "\n".join(l for l in isolated if l.strip())
    if not isolated_code.strip():
        log.warning(f"No content found in range {start_line}-{end_line}.")
        return

    log.info(f"Isolated lines {start_line}-{end_line} "
             f"({len(isolated)} lines in section).")

    # --- Step 6: clang-format ---
    with tempfile.NamedTemporaryFile(delete=False, suffix=".cpp", mode="w") as tmp:
        tmp.write(isolated_code)
        tmp_path = tmp.name

    try:
        fmt = subprocess.run(
            ["clang-format", "-style=file", tmp_path],
            capture_output=True,
            text=True
        )
        print(fmt.stdout if fmt.returncode == 0 else isolated_code)
    finally:
        if os.path.exists(tmp_path):
            os.remove(tmp_path)
        
def main():
    update_compile_commands()

    if "--update-index" in sys.argv:
        return
    
    test_file = None
    performance_test = False
    if len(sys.argv) >= 3 and "test" in sys.argv:
        for arg in sys.argv:
            if arg.endswith(".kro"):
                if test_file is not None:
                    log.error("Only one test file can be specified at a time.")
                    return
                
                test_file = arg
            if arg == "--perf":
                performance_test = True

    if len(sys.argv) >= 3 and sys.argv[1] == "line":
        file = sys.argv[2]
        line_range = sys.argv[3] if len(sys.argv) >= 4 else None
        return extract_cpp_from_ir(file, line_range)

    if test_file is not None:
        test_path = Path(test_file)
        if not test_path.exists():
            log.error(f"Test file {test_file} does not exist.")
            return
        else:
            return test(test_path, performance_test)
    
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