import os
import sys
import subprocess
import platform
import argparse
import json
import shutil
import multiprocessing
import logging

# Configure the logging
logging.basicConfig(
    level=logging.DEBUG,                  # Set the logging level
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',  # Define the format
    datefmt='%Y-%m-%d %H:%M:%S'          # Define the date format
)

# Get a logger object
logger = logging.getLogger(__name__)


# Constants
VERSION = "18.1.8" # leave blank for latest llvm version
LLVM_REPO = "https://github.com/llvm/llvm-project.git"
BUILD_DIR = os.path.abspath("./build")
LLVM_SRC_DIR = f"{BUILD_DIR}/llvm/llvm-{VERSION if VERSION else 'latest'}-src"
BUILD_CONFIG_FILE = f"{BUILD_DIR}/build_config.json"
REQUIRED_TOOLS = ["git", "cmake", "ninja", "clang" if platform.system() != "Windows" else "cl"]
LLVM_VERSION_TAG = f"llvmorg-{VERSION}"
CORE_TIER_TARGETS = {
    "AArch64", "AMDGPU", "ARM", "AVR", "BPF", "Hexagon", "Lanai", "LoongArch", "Mips",
    "MSP430", "NVPTX", "PowerPC", "RISCV", "Sparc", "SystemZ", "VE", "WebAssembly", "X86", "XCore"
}
EXPERIMENTAL_TARGETS = {"ARC", "CSKY", "DirectX", "M68k", "SPIRV", "Xtensa"}


force_install = False
threads = multiprocessing.cpu_count() * (2 if sys.platform != "win32" else 1)
call_stack = []

class Colors:
    red = "\u001b[91m"
    green = "\u001b[92m"
    reset = "\u001b[0m"

# Utility functions
def check_prerequisites():
    missing_tools = []
    for tool in REQUIRED_TOOLS:
        if not shutil.which(tool):
            missing_tools.append(tool)
    if missing_tools:
        print(f"{Colors.red}error:{Colors.reset} The following required tools are not installed: {', '.join(missing_tools)}")
        sys.exit(1)

def clone_llvm_source():
    if not os.path.exists(LLVM_SRC_DIR):
        os.makedirs(os.path.dirname(LLVM_SRC_DIR), exist_ok=True)

        if VERSION:
            run_command(f"git clone --branch {LLVM_VERSION_TAG} --depth 1 {LLVM_REPO} {LLVM_SRC_DIR}")
        else:
            run_command(f"git clone --depth 1 {LLVM_REPO} {LLVM_SRC_DIR}")


def run_command(command, cwd=None, check=True):
    call_stack.append(command)
    result = subprocess.run(command, shell=True, cwd=cwd, check=check)
    return result.returncode

def save_config(config):
    with open(BUILD_CONFIG_FILE, "w") as f:
        json.dump(config, f, indent=4)

def load_config():
    if os.path.exists(BUILD_CONFIG_FILE):
        with open(BUILD_CONFIG_FILE, "r") as f:
            return json.load(f)
    return {}

def build_llvm_host(config):
    logger.info("Building LLVM+CLANG for host")

    if "host_target" not in config:
        allowed_targets = list(CORE_TIER_TARGETS) + list(EXPERIMENTAL_TARGETS)
        host_target = input(f"Enter the host target to build stage 0, chose from: "
                            f"[{', '.join([Colors.green + x + Colors.reset for x in allowed_targets])}]"
                            "\n>>> ")

        if host_target not in allowed_targets:
            for targ in allowed_targets:
                if host_target.lower() == targ.lower():
                    host_target = targ
                    break
            else:
                print(Colors.red + "error: " + Colors.reset + f"the target {host_target} is not valid.")
                sys.exit(1)

        config["host_target"] = host_target
        save_config(config)
    else:
        host_target = config["host_target"]

    if host_target in CORE_TIER_TARGETS:
        target_flag = f"-DLLVM_TARGETS_TO_BUILD={host_target}"
    elif host_target in EXPERIMENTAL_TARGETS:
        target_flag = f"-DLLVM_EXPERIMENTAL_TARGETS_TO_BUILD={host_target}"


    llvm_build_dir = f"{BUILD_DIR}/llvm/llvm-build-host"
    if not os.path.exists(llvm_build_dir) or force_install:
        os.makedirs(llvm_build_dir, exist_ok=True)

        cmake_command = (
            f"cmake -S {LLVM_SRC_DIR}/llvm -B {llvm_build_dir} -G Ninja "
            f"{target_flag} -DCMAKE_BUILD_TYPE=Release "
            f"-DLLVM_ENABLE_PROJECTS=\"clang;llvm;lld;clang-tools-extra\" "
            f"-DLLVM_ENABLE_RUNTIMES=\"libcxx;libcxxabi;libunwind\" "
            f"-DLLVM_ENABLE_LIBCXX=ON -DLLVM_INCLUDE_TESTS=OFF "
        )
        run_command(cmake_command, cwd=llvm_build_dir)
        run_command(f"ninja -j {threads} install", cwd=llvm_build_dir)
        run_command(f"ninja clang-tblgen", cwd=llvm_build_dir)
        run_command(f"ninja clang-headers", cwd=llvm_build_dir)
    return llvm_build_dir


# def build_llvm(target):
#     llvm_build_dir = f"{BUILD_DIR}/llvm/llvm-build-{target}"

#     if target in CORE_TIER_TARGETS:
#         target_flag = f"-DLLVM_TARGETS_TO_BUILD={target}"
#     elif target in EXPERIMENTAL_TARGETS:
#         target_flag = f"-DLLVM_EXPERIMENTAL_TARGETS_TO_BUILD={target}"
#     else:
#         print(f"{Colors.red}error:{Colors.reset} The target '{target}' is not recognized as a target. chose from the following")
#         sys.exit(1)

#     if not os.path.exists(llvm_build_dir):
#         os.makedirs(llvm_build_dir, exist_ok=True)
#         cmake_command = (
#             f"cmake -S {os.path.abspath(LLVM_SRC_DIR)}/llvm -B {llvm_build_dir} -G Ninja "
#             f"{target_flag} "
#             f"-DCMAKE_BUILD_TYPE=Release -DLLVM_ENABLE_PROJECTS=clang "
#             f"-DLLVM_ENABLE_LIBCXX=ON -DLLVM_ENABLE_LIBCXXABI=ON"
#         )
#         run_command(cmake_command, cwd=llvm_build_dir)
#         run_command("ninja", cwd=llvm_build_dir)
#     return llvm_build_dir


def build_llvm_target(target, mcpu, llvm_host_build):
    logger.info(f"Building LLVM+CLANG for {target}-{mcpu}")
    target_os_map = {
        "macos": "Darwin",
        "freebsd": "FreeBSD",
        "windows": "Windows",
        "linux": "Linux",
        "native": ""
    }

    target_os_cmake = target.split("-", 1)[1].rsplit("-", 1)[0]
    target_os_cmake = target_os_map.get(target_os_cmake, target_os_cmake)

    llvm_build_dir = f"{BUILD_DIR}/llvm/llvm-build-{target}-{mcpu}"
    if not os.path.exists(llvm_build_dir) or force_install:
        os.makedirs(llvm_build_dir, exist_ok=True)

        cmake_command = (
            f"cmake -S {LLVM_SRC_DIR}/llvm -B {llvm_build_dir} -G Ninja "
            f"-DCMAKE_BUILD_TYPE=Release -DCMAKE_CROSSCOMPILING=True "
            f"-DCMAKE_SYSTEM_NAME={target_os_cmake} "
            f"-DLLVM_ENABLE_PROJECTS=\"clang;llvm;lld;clang-tools-extra\" "
            f"-DLLVM_ENABLE_RUNTIMES=\"libcxx;libcxxabi;libunwind\" "
            f"-DLLVM_ENABLE_LIBCXX=ON -DLLVM_INCLUDE_TESTS=OFF "
            f"-DLLVM_TABLEGEN={llvm_host_build}/bin/llvm-tblgen "
            f"-DCLANG_TABLEGEN={llvm_host_build}/bin/clang-tblgen "
        )

        run_command(cmake_command, cwd=llvm_build_dir)
        run_command(f"ninja -j {threads} install", cwd=llvm_build_dir)
        run_command(f"ninja clang-tblgen")
        run_command(f"ninja clang-headers")

    return llvm_build_dir

def generate_cmake(target, build_type): # , llvm_build_dir
    build_dir = f"{BUILD_DIR}/build-{target}-{build_type}"
    if not os.path.exists(build_dir) or force_install:
        os.makedirs(build_dir, exist_ok=True)
        cmake_command = (
            f"cmake ../.. -DCMAKE_BUILD_TYPE={build_type} "
            #f"-DLLVM_DIR={llvm_build_dir}/lib/cmake/llvm "
            #f"-DCMAKE_CXX_FLAGS=\"-fuse-ld={os.path.join(llvm_build_dir, 'bin', 'ld.lld')}\" "
            #f"-DLLVM_TABLEGEN={llvm_build_dir}/bin/llvm-tblgen "
            #f"-DCLANG_TABLEGEN={llvm_build_dir}/bin/clang-tblgen "
        )
        run_command(cmake_command, cwd=build_dir)
    return build_dir

def compile_project(build_dir):
    run_command("cmake --build . --parallel", cwd=build_dir)

def main():
    global force_install, threads

    check_prerequisites()

    parser = argparse.ArgumentParser(description="Build script for Kairo project")
    parser.add_argument("build_type", choices=["debug", "release"], help="Build type")
    parser.add_argument("--target", required=False, help="Target triple")
    parser.add_argument("--mcpu", required=False, help="MCPU type")
    parser.add_argument("--force", action="store_true", help="Force install")
    parser.add_argument("--threads", help="Number of threads to use")
    parser.add_argument("--cross", action="store_true", help="Cross Compile Kairo")

    parser.add_argument("action", choices=["build", "run"], help="Action to perform")

    args = parser.parse_args()
    build_type = args.build_type
    target = args.target
    mcpu = args.mcpu
    action = args.action
    force_install = args.force
    threads = args.threads if args.threads else threads
    cross_compile = args.cross

    config = load_config()
    if "cache" not in config:
        config["cache"] = []

    # if "host" not in config:
    #     if "llvm_src_installed" not in config["cache"]:
    #         clone_llvm_source()
    #         config["cache"].append("llvm_src_installed")

    #     if "llvm_host_built" not in config["cache"]:
    #         llvm_build_dir_host = build_llvm_host(config)
    #         config["host"]  = {"llvm_build_dir": llvm_build_dir_host}
    #         config["cache"].append("llvm_host_built")
    #
    #     save_config(config)
    # else:
    #     llvm_build_dir_host = config["host"]["llvm_build_dir"]

    # if target not in config and cross_compile:
    #     llvm_build_dir_target = build_llvm_target(target, mcpu, llvm_build_dir_host)
    #     config[target] = {"llvm_build_dir": llvm_build_dir_target}
    #     save_config(config)
    # else:
    #     if cross_compile:
    #         llvm_build_dir_target = config[target]["llvm_build_dir"]
    #     else:
    #         llvm_build_dir_target = llvm_build_dir_host

    # Set the environment variable for LLVM_DIR
    # os.environ["LLVM_DIR"]       = llvm_build_dir_target
    # os.environ["LLVM_SRC_DIR"]   = LLVM_SRC_DIR
    # os.environ["LLVM_TABLEGEN"]  = os.path.join(llvm_build_dir_host, "bin", "llvm-tblgen")
    # os.environ["CLANG_TABLEGEN"] = os.path.join(llvm_build_dir_host, "bin", "clang-tblgen")
    # os.environ["CC"]             = os.path.join(llvm_build_dir_host, "bin", "clang-18")
    # os.environ["CXX"]            = os.path.join(llvm_build_dir_host, "bin", "clang++")
    print("ENVIRONMENT VARIABLES:\n" +
          '\n    '.join([
                f"{Colors.red}{key:<30}{Colors.reset} = {Colors.green}\"{os.environ[key]}\"{Colors.reset}"
                for key in os.environ.keys()
              ]) +
          "\n\n")

    build_dir = generate_cmake(target, build_type) # llvm_build_dir_target

    if action == "build":
        compile_project(build_dir)
    elif action == "run":
        executable = os.path.join(build_dir, "kairo")
        if platform.system() == "Windows":
            executable += ".exe"
        run_command(executable, check=False)

if __name__ == "__main__":
    try:
        main()
    except (Exception, KeyboardInterrupt) as e:
        print(e)
        print(Colors.red + "call stack: " + Colors.reset + f"[{', '.join([(Colors.green + '\"' + x + '\"' + Colors.reset) for x in call_stack])}]")