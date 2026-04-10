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
    proc = subprocess.run(
        ['c++filt', '--no-strip-underscores'],
        input='\n'.join(symbols),
        capture_output=True,
        text=True
    )
    demangled = proc.stdout.strip().split('\n')
    if len(demangled) != len(symbols):
        return text
    result = text
    for m, dem in zip(reversed(tokens), reversed(demangled)):
        result = result[:m.start()] + dem + result[m.end():]
    return result

def clean(text):
    text = cppfilt_tokens(text)
    text = demangle_kairo_partial(text)
    text = re.sub(r'\bkairo::', '', text)
    text = text.replace('std::__1::', 'std::')
    text = text.replace('[abi:nqe220102]', '')
    return text

# --- lldb symbol demangler hook ---
def kairo_demangle(name, internal_dict):
    """Called by lldb to demangle a symbol name."""
    result = clean(name)
    return result if result != name else None

# --- bt command that pretty-prints backtraces ---
def kairo_bt(debugger, command, result, internal_dict):
    """bt replacement with Kairo demangling."""
    interpreter = debugger.GetCommandInterpreter()
    ret = lldb.SBCommandReturnObject()
    interpreter.HandleCommand('thread backtrace', ret)
    output = ret.GetOutput() or ''
    for line in output.splitlines():
        print(clean(line))

# --- frame command wrapper ---
def kairo_frame(debugger, command, result, internal_dict):
    """frame info with Kairo demangling."""
    interpreter = debugger.GetCommandInterpreter()
    ret = lldb.SBCommandReturnObject()
    interpreter.HandleCommand(f'frame {command}', ret)
    output = ret.GetOutput() or ''
    for line in output.splitlines():
        print(clean(line))

def __lldb_init_module(debugger, internal_dict):
    # register the demangler with lldb
    debugger.HandleCommand(
        'type synthetic add -l lldb.formatters.cpp.libcxx.stdstring_SynthProvider std::string'
    )

    # register kbt and kframe commands
    debugger.HandleCommand(
        'command script add -f lldb_kairo.kairo_bt kbt'
    )
    debugger.HandleCommand(
        'command script add -f lldb_kairo.kairo_frame kframe'
    )

    # hook into lldb's demangler
    debugger.HandleCommand(
        'settings set target.language c++'
    )

    print('Kairo lldb plugin loaded. Use `kbt` for demangled backtraces.')