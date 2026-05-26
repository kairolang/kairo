# ~/.config/kairo/lldb_kairo.py
import lldb
import re
import subprocess

def is_hex_digit(c):
    return c in '0123456789abcdefABCDEF'

def basename_no_ext(path):
    path = path.replace('\\', '/')
    name = path.rsplit('/', 1)[-1]
    if '.' in name:
        name = name.rsplit('.', 1)[0]
    return name

TYPE_MAP = {
    'M': ('_$M_', 4, True),
    'C': ('_$C_', 4, False),
    'S': ('_$S_', 4, False),
    'F': ('_$F_', 4, False),
    'O': ('_$O_', 4, False),
    'R': ('_$R_', 4, False),
    'I': ('_$I_', 4, False),
}

# --- demangling cache to avoid repeated subprocess calls ---
_demangle_cache = {}

def demangle_kairo_segment(mangled, prefix_len):
    len_pos = mangled.rfind('$L')
    end_pos = mangled.rfind('_E$')
    if len_pos == -1 or end_pos == -1 or end_pos <= len_pos:
        return None
    try:
        expected_len = int(mangled[len_pos + 2:end_pos])
    except ValueError:
        return None
    encoded = mangled[prefix_len:len_pos]
    output = []
    i = 0
    while i < len(encoded):
        if encoded[i] == '$':
            j = i + 1
            count = 0
            while j < len(encoded) and count < 4 and is_hex_digit(encoded[j]):
                j += 1
                count += 1
            if count in (2, 4):
                code = int(encoded[i+1:i+1+count], 16)
                output.append(chr(code))
                i = j
                continue
        output.append(encoded[i])
        i += 1
    result = ''.join(output)
    if len(result) != expected_len:
        return None
    return result

def demangle_kairo_partial(text):
    result = []
    i = 0
    while i < len(text):
        if (i + 3 < len(text) and
            text[i] == '_' and text[i+1] == '$' and
            text[i+2] in TYPE_MAP and text[i+3] == '_'):
            type_char = text[i+2]
            prefix, prefix_len, is_module = TYPE_MAP[type_char]
            end_pos = text.find('_E$', i)
            if end_pos == -1:
                result.append(text[i])
                i += 1
                continue
            mangled = text[i:end_pos + 3]
            demangled = demangle_kairo_segment(mangled, prefix_len)
            if demangled is not None:
                if is_module:
                    demangled = basename_no_ext(demangled)
                result.append(demangled)
                i = end_pos + 3
                continue
        result.append(text[i])
        i += 1
    return ''.join(result)

MANGLED_RE = re.compile(r'\b(_Z[A-Za-z0-9_$]+|__Z[A-Za-z0-9_$]+)')

def cppfilt_tokens(text):
    tokens = list(MANGLED_RE.finditer(text))
    if not tokens:
        return text

    symbols = [m.group(0) for m in tokens]

    # check cache, only send uncached symbols to c++filt
    uncached = []
    uncached_indices = []
    for idx, sym in enumerate(symbols):
        if sym not in _demangle_cache:
            uncached.append(sym)
            uncached_indices.append(idx)

    if uncached:
        try:
            proc = subprocess.run(
                ['c++filt', '--no-strip-underscores'],
                input='\n'.join(uncached),
                capture_output=True,
                text=True,
                timeout=5
            )
            demangled = proc.stdout.strip().split('\n')
            if len(demangled) == len(uncached):
                for i, dem in enumerate(demangled):
                    _demangle_cache[uncached[i]] = dem
            else:
                # c++filt gave unexpected output, cache as identity
                for sym in uncached:
                    _demangle_cache[sym] = sym
        except (subprocess.TimeoutExpired, FileNotFoundError):
            for sym in uncached:
                _demangle_cache[sym] = sym

    result = text
    for m, sym in zip(reversed(tokens), reversed(symbols)):
        result = result[:m.start()] + _demangle_cache[sym] + result[m.end():]
    return result

def clean(text):
    text = cppfilt_tokens(text)
    text = demangle_kairo_partial(text)
    text = re.sub(r'\bkairo::', '', text)
    text = text.replace('std::__1::', 'std::')
    text = text.replace('[abi:nqe220102]', '')
    return text


# ---------------------------------------------------------------------------
# lldb command wrappers
# ---------------------------------------------------------------------------

def _run_and_clean(debugger, real_cmd):
    """Run a built-in lldb command and print its output through clean()."""
    interpreter = debugger.GetCommandInterpreter()
    ret = lldb.SBCommandReturnObject()
    interpreter.HandleCommand(real_cmd, ret)
    out = ret.GetOutput() or ''
    for line in out.splitlines():
        print(clean(line))
    err = ret.GetError() or ''
    for line in err.splitlines():
        print(clean(line))

def wrap_bt(debugger, command, result, internal_dict):
    _run_and_clean(debugger, f'thread backtrace {command}'.strip())

def wrap_up(debugger, command, result, internal_dict):
    count = command.strip() if command.strip() else '1'
    _run_and_clean(debugger, f'frame select -r {count}')

def wrap_down(debugger, command, result, internal_dict):
    count = command.strip() if command.strip() else '1'
    _run_and_clean(debugger, f'frame select -r -{count}')

def wrap_frame(debugger, command, result, internal_dict):
    _run_and_clean(debugger, f'frame {command}'.strip())

def wrap_thread_info(debugger, command, result, internal_dict):
    _run_and_clean(debugger, f'thread info {command}'.strip())

def wrap_thread_list(debugger, command, result, internal_dict):
    _run_and_clean(debugger, f'thread list {command}'.strip())

def wrap_image_lookup(debugger, command, result, internal_dict):
    _run_and_clean(debugger, f'image lookup {command}'.strip())

def stop_hook_handler(debugger, command, result, internal_dict):
    """Auto-demangle the current frame on every stop."""
    target = debugger.GetSelectedTarget()
    if not target:
        return
    process = target.GetProcess()
    if not process:
        return
    thread = process.GetSelectedThread()
    if not thread:
        return
    frame = thread.GetSelectedFrame()
    if not frame:
        return

    # build a frame summary line manually from the SB API
    idx = frame.GetFrameID()
    module = frame.GetModule()
    mod_name = module.GetFileSpec().GetFilename() if module else '??'
    pc = frame.GetPC()
    func = frame.GetFunctionName() or '???'
    line_entry = frame.GetLineEntry()

    display = f'frame #{idx}: 0x{pc:016x} {mod_name}`{func}'
    if line_entry.IsValid():
        f_spec = line_entry.GetFileSpec()
        display += f' at {f_spec.GetFilename()}:{line_entry.GetLine()}'

    print(clean(display))


# ---------------------------------------------------------------------------
# init
# ---------------------------------------------------------------------------

def __lldb_init_module(debugger, internal_dict):
    mod = 'lldb_kairo'

    # these accept -o override
    debugger.HandleCommand(f'command script add -o -f {mod}.wrap_bt bt')
    debugger.HandleCommand(f'command script add -o -f {mod}.wrap_up up')
    debugger.HandleCommand(f'command script add -o -f {mod}.wrap_down down')

    # these can't override builtins, use k-prefixed aliases
    debugger.HandleCommand(f'command script add -f {mod}.wrap_frame kframe')
    debugger.HandleCommand(f'command script add -f {mod}.wrap_thread_info kti')
    debugger.HandleCommand(f'command script add -f {mod}.wrap_thread_list ktl')
    debugger.HandleCommand(f'command script add -f {mod}.wrap_image_lookup kimg')

    # stop-hook for demangling on every break/step
    debugger.HandleCommand(f'target stop-hook add -P {mod}.KairoStopHook')

    print('Kairo lldb plugin loaded.')
    print('  bt/up/down demangled natively.')
    print('  kframe, kti, ktl, kimg for the rest.')

class KairoStopHook:
    """Class-based stop hook — cleaner than shelling out to script."""
    def __init__(self, target, extra_args, internal_dict):
        pass

    def handle_stop(self, exe_ctx, stream):
        frame = exe_ctx.GetFrame()
        if not frame or not frame.IsValid():
            return True

        idx = frame.GetFrameID()
        module = frame.GetModule()
        mod_name = module.GetFileSpec().GetFilename() if module else '??'
        pc = frame.GetPC()
        func = frame.GetFunctionName() or '???'
        line_entry = frame.GetLineEntry()

        display = f'  * frame #{idx}: 0x{pc:016x} {mod_name}`{func}'
        if line_entry.IsValid():
            f_spec = line_entry.GetFileSpec()
            display += f' at {f_spec.GetFilename()}:{line_entry.GetLine()}'

        stream.Print(clean(display) + '\n')
        return True  # don't suppress the stop