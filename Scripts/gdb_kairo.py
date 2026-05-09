#!/usr/bin/env python3
"""GDB Kairo demangler — type printer + frame filter for clean names in VSCode."""

import gdb
import gdb.types
import gdb.FrameDecorator
import re

# ---------------------------------------------------------------------------
#  Kairo demangler (same logic as kairo-demangle.py)
# ---------------------------------------------------------------------------

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

def demangle_kairo(text):
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
    out = ''.join(result)
    out = re.sub(r'\bkairo::', '', out)
    out = out.replace('std::__1::', 'std::')
    out = out.replace('[abi:nqe220102]', '')
    return out


# ---------------------------------------------------------------------------
#  Type printer — cleans up type names in the Variables panel
# ---------------------------------------------------------------------------

class KairoTypePrinter(gdb.types.TypePrinter):
    def __init__(self):
        super().__init__("KairoDemangler")

    def instantiate(self):
        return KairoTypeRecognizer()

class KairoTypeRecognizer:
    def recognize(self, type_obj):
        name = str(type_obj.tag) if type_obj.tag else str(type_obj)
        if '_$' in name or 'kairo::' in name:
            cleaned = demangle_kairo(name)
            if cleaned != name:
                return cleaned
        return None


# ---------------------------------------------------------------------------
#  Frame filter — cleans up function names in the Call Stack panel
# ---------------------------------------------------------------------------

class KairoFrameDecorator(gdb.FrameDecorator.FrameDecorator):
    def __init__(self, fobj):
        super().__init__(fobj)

    def function(self):
        name = self.inferior_frame().name()
        if name and ('_$' in name or 'kairo::' in name):
            return demangle_kairo(name)
        return name

class KairoFrameFilter:
    def __init__(self):
        self.name = "KairoFrameFilter"
        self.priority = 100
        self.enabled = True
        gdb.frame_filters[self.name] = self

    def filter(self, frame_iter):
        for frame in frame_iter:
            yield KairoFrameDecorator(frame)


# ---------------------------------------------------------------------------
#  Pretty printer — cleans up type names when printing values
# ---------------------------------------------------------------------------

try:
    _PrettyPrinterBase = gdb.printing.PrettyPrinter
except AttributeError:
    _PrettyPrinterBase = object

class KairoPrettyPrinter(_PrettyPrinterBase):
    def __init__(self):
        super().__init__("KairoPrettyPrinter")

    def __call__(self, val):
        t = val.type
        name = str(t.tag) if t.tag else str(t)
        if '_$' in name or 'kairo::' in name:
            return KairoValuePrinter(val, demangle_kairo(name))
        return None

class KairoValuePrinter:
    def __init__(self, val, display_name):
        self.val = val
        self.display_name = display_name

    def to_string(self):
        return f"({self.display_name}) {self.val.format_string(raw=True)}"


# ---------------------------------------------------------------------------
#  Commands — kbt for demangled backtraces in the debug console
# ---------------------------------------------------------------------------

class KairoBtCommand(gdb.Command):
    """Demangled backtrace."""
    def __init__(self):
        super().__init__("kbt", gdb.COMMAND_STACK)

    def invoke(self, arg, from_tty):
        try:
            frame = gdb.newest_frame()
        except gdb.error:
            print("No stack.")
            return

        idx = 0
        while frame is not None:
            name = frame.name() or "??"
            name = demangle_kairo(name)
            sal = frame.find_sal()
            if sal.symtab:
                loc = f"{sal.symtab.filename}:{sal.line}"
            else:
                loc = f"0x{frame.pc():x}"
            print(f"#{idx:<3} {name} at {loc}")
            frame = frame.older()
            idx += 1


class KairoPrintType(gdb.Command):
    """Print demangled type of expression: ktype <expr>"""
    def __init__(self):
        super().__init__("ktype", gdb.COMMAND_DATA)

    def invoke(self, arg, from_tty):
        try:
            val = gdb.parse_and_eval(arg)
            t = str(val.type)
            print(demangle_kairo(t))
        except gdb.error as e:
            print(f"error: {e}")


# ---------------------------------------------------------------------------
#  Registration
# ---------------------------------------------------------------------------


gdb.types.register_type_printer(None, KairoTypePrinter())
KairoFrameFilter()
KairoBtCommand()
KairoPrintType()

# Pretty printer — only register if gdb.printing exists
try:
    gdb.printing.register_pretty_printer(None, KairoPrettyPrinter(), replace=True)
except AttributeError:
    # older GDB without gdb.printing module, skip pretty printer
    pass

print("[kairo] GDB demangler loaded: type printer, frame filter, kbt, ktype")