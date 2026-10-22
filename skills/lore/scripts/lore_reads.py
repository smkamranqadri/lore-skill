#!/usr/bin/env python3
"""lore read tracking: which memory files did the agent open in one session transcript.

reads(fmt, transcript_path, store_root) -> {path relative to store_root: read calls}.
Pure and read-only: it opens the transcript and nothing else, and writes no store.
"""
import json
import os
import re
import shlex

FORMATS = ("claude", "codex", "agy", "generic")

# Tool names (per host) that read a file, with the argument that holds the path(s).
READ_TOOLS = {
    "Read": ("file_path",),                    # claude
    "Grep": ("path",),                         # claude, a file path as the search target
    "view_file": ("AbsolutePath",),            # agy
    "read_file": ("file_path", "path", "paths"),   # generic (Command Code)
    "grep": ("path",),                         # generic
}
# Tool names that run a shell command, with the argument that holds it.
SHELL_TOOLS = {
    "Bash": ("command",),
    "run_command": ("CommandLine",),
    "shell_command": ("command",),
    "exec_command": ("cmd", "command"),
    "shell": ("command", "cmd"),
}
# Shell commands that read the files named on their command line.
READ_CMDS = {"cat", "head", "tail", "less", "more", "bat", "nl", "sed", "grep", "rg", "egrep", "fgrep"}
# These take a pattern or script as the first non-option word (unless -e is given).
PATTERN_CMDS = {"sed", "grep", "rg", "egrep", "fgrep"}
# Long options (written without =) whose next word is a value, not an operand.
LONG_VALUED = {"--max-count", "--after-context", "--before-context", "--context", "--glob", "--iglob",
               "--type", "--type-not", "--include", "--exclude", "--exclude-dir", "--color", "--colour",
               "--devices", "--directories", "--label", "--replace", "--threads", "--max-depth",
               "--encoding", "--max-columns", "--line-length"}
WRAPPERS = {"sudo", "env", "command", "time", "nice", "exec"}
SHELLS = {"bash", "sh", "zsh"}


def supported(fmt):
    return fmt in FORMATS


def _expand(p):
    return os.path.realpath(os.path.expandvars(os.path.expanduser(p)))


def _rel(path, root, expand=True):
    """`path` relative to `root` with "/", or None unless the normalised path is a .md file in
    the store and not under .lore/. `expand` is False for shell words, which the tokenizer has
    already expanded (so a quoted '$HOME/x.md' stays literal and is rejected)."""
    if not isinstance(path, str) or not path:
        return None
    if expand:
        if not (path.startswith(("/", "~", "$"))):
            return None
        full = _expand(path)
    else:
        if not path.startswith("/"):
            return None
        full = os.path.realpath(path)
    if not full.endswith(".md") or not full.startswith(root + os.sep):
        return None
    rel = full[len(root) + 1:]
    if ".lore" in rel.split(os.sep):
        return None
    return rel.replace(os.sep, "/")


# ---- shell ------------------------------------------------------------------------------------

def _home():
    return os.environ.get("HOME") or os.path.expanduser("~")


def _var(s, j):
    """Expansion of the $ at s[j]: (text, next index). Only HOME is expanded."""
    if s.startswith("${HOME}", j):
        return _home(), j + 7
    if s.startswith("$HOME", j) and not (j + 5 < len(s) and (s[j + 5].isalnum() or s[j + 5] == "_")):
        return _home(), j + 5
    return "$", j + 1


def _parse_shell(s):
    """Simple commands of a shell string as (words, redirects). Quotes are resolved here, so a
    quoted ; or newline is text and a single-quoted $HOME stays literal; unquoted newlines end
    a command; heredoc bodies are skipped through their delimiter; $(...) is not evaluated.
    redirects is a list of (operator, target word)."""
    cmds, words, reds, cur = [], [], [], []
    st = {"has": False, "op": None}
    heredocs = []
    n = len(s)

    def end_word():
        if not st["has"]:
            return
        w = "".join(cur)
        del cur[:]
        st["has"] = False
        if st["op"] is not None:
            reds.append((st["op"], w))
            if st["op"] in ("<<", "<<-"):
                heredocs.append((w, st["op"] == "<<-"))
            st["op"] = None
        else:
            words.append(w)

    def end_cmd():
        end_word()
        st["op"] = None
        if words or reds:
            cmds.append((list(words), list(reds)))
        del words[:]
        del reds[:]

    i = 0
    while i < n:
        c = s[i]
        if c in " \t":
            end_word()
            i += 1
        elif c == "\n":
            end_cmd()
            i += 1
            for delim, strip in heredocs:
                while i < n:
                    j = s.find("\n", i)
                    line = s[i:] if j < 0 else s[i:j]
                    i = n if j < 0 else j + 1
                    if (line.lstrip("\t") if strip else line) == delim:
                        break
            heredocs = []
        elif c == "\\":
            if i + 1 < n and s[i + 1] != "\n":
                cur.append(s[i + 1])
                st["has"] = True
            i += 2
        elif c == "'":
            j = s.find("'", i + 1)
            j = n if j < 0 else j
            cur.append(s[i + 1:j])
            st["has"] = True
            i = j + 1
        elif c == '"':
            j = i + 1
            while j < n and s[j] != '"':
                if s[j] == "\\" and j + 1 < n and s[j + 1] in '"\\$`\n':
                    if s[j + 1] != "\n":
                        cur.append(s[j + 1])
                    j += 2
                elif s[j] == "$":
                    t, j = _var(s, j)
                    cur.append(t)
                else:
                    cur.append(s[j])
                    j += 1
            st["has"] = True
            i = j + 1
        elif c == "$":
            t, i = _var(s, i)
            cur.append(t)
            st["has"] = True
        elif c == "~" and not st["has"] and (i + 1 == n or s[i + 1] in "/ \t\n;&|<>"):
            cur.append(_home())
            st["has"] = True
            i += 1
        elif c == "#" and not st["has"]:
            j = s.find("\n", i)
            i = n if j < 0 else j
        elif c == "&" and s[i + 1:i + 2] == ">":
            end_word()
            st["op"] = ">"
            i += 3 if s[i + 2:i + 3] == ">" else 2
        elif c in ";&|":
            end_cmd()
            i += 1
        elif c in "<>":
            if st["has"] and "".join(cur).isdigit():   # a file-descriptor prefix: 2>
                del cur[:]
                st["has"] = False
            else:
                end_word()
            op = next(o for o in ("<<<", "<<-", "<<", ">>", "<>", ">&", "<&", ">|", "<", ">") if s.startswith(o, i))
            st["op"] = op
            i += len(op)
        else:
            cur.append(c)
            st["has"] = True
            i += 1
    end_cmd()
    return cmds


def _strip_wrappers(words):
    while words:
        if words[0] in WRAPPERS:
            words = words[1:]
            while words and words[0].startswith("-"):
                words = words[1:]
        elif re.match(r"^\w+=", words[0]):
            words = words[1:]
        else:
            break
    return words


def _split_opts(args, valued, pattern_opts, file_opts):
    """Split a command's arguments into (operands, pattern_given, option file operands).
    `valued` holds short options that take a value, `pattern_opts` the short/long forms that
    supply the pattern or script, `file_opts` those whose value is a file (grep -f, sed -f)."""
    operands, files, pat = [], [], False
    i = 0
    while i < len(args):
        a = args[i]
        i += 1
        if a == "--":
            operands.extend(args[i:])
            break
        if a.startswith("--"):
            name, eq, val = a.partition("=")
            takes = name in LONG_VALUED
            if name in pattern_opts or name in file_opts:
                if not eq and i < len(args):
                    val = args[i]
                    i += 1
                pat = True
                if name in file_opts:
                    files.append(val)
            elif takes and not eq:
                i += 1
        elif a.startswith("-") and len(a) > 1:
            k = 1
            while k < len(a):
                ch = a[k]
                if ch in valued or "-" + ch in pattern_opts or "-" + ch in file_opts:
                    val = a[k + 1:]
                    if not val and i < len(args):
                        val = args[i]
                        i += 1
                    if "-" + ch in pattern_opts or "-" + ch in file_opts:
                        pat = True
                    if "-" + ch in file_opts:
                        files.append(val)
                    break
                k += 1
        else:
            operands.append(a)
    return operands, pat, files


def _sed_in_place(args):
    for a in args:
        if a == "--":
            break
        if a.startswith("--in-place"):
            return True
        if a.startswith("-") and not a.startswith("--"):
            for ch in a[1:]:
                if ch == "i":
                    return True
                if ch in "efl":   # the rest of the cluster is a value, not flags
                    break
    return False


def _command_paths(words, reds, depth):
    words = _strip_wrappers(words)
    if not words:
        return []
    name = os.path.basename(words[0])
    args = words[1:]
    if name in SHELLS:
        for i, a in enumerate(args):
            if re.match(r"^-[a-zA-Z]*c[a-zA-Z]*$", a):
                return _shell_paths(args[i + 1], depth + 1) if i + 1 < len(args) and depth < 3 else []
        return []
    if name not in READ_CMDS:
        return []
    if name == "sed":
        if _sed_in_place(args):
            return []
        operands, pat, files = _split_opts(args, "l", ("-e", "--expression"), ("-f", "--file"))
    elif name in PATTERN_CMDS:
        valued = "mABCdD" if name != "rg" else "gtTmABCjMrEd"
        operands, pat, files = _split_opts(args, valued, ("-e", "--regexp"), ("-f", "--file"))
        if "--files" in args:
            pat = True
    else:
        operands, pat, files = _split_opts(args, "nc" if name in ("head", "tail") else "", (), ())
    if name in PATTERN_CMDS and not pat and operands:
        operands = operands[1:]
    paths = operands + files
    paths.extend(t for op, t in reds if op == "<")
    return paths


def _shell_paths(cmd, depth=0):
    paths = []
    for words, reds in _parse_shell(cmd):
        paths.extend(_command_paths(words, reds, depth))
    return paths


# ---- Codex JS cells ---------------------------------------------------------------------------

_ESC = {"n": "\n", "t": "\t", "r": "\r", "b": "\b", "f": "\f", "v": "\v", "0": "\0"}


def _js_string(s, i):
    """Decode the JS string literal at s[i]: (value, next index). The value is None for a
    template literal with ${...} (not a literal)."""
    q, j, out, lit, n = s[i], i + 1, [], True, len(s)
    while j < n and s[j] != q:
        c = s[j]
        if c == "\\" and j + 1 < n:
            e = s[j + 1]
            try:
                if e in _ESC:
                    out.append(_ESC[e])
                    j += 2
                elif e == "x":
                    out.append(chr(int(s[j + 2:j + 4], 16)))
                    j += 4
                elif e == "u" and s[j + 2:j + 3] == "{":
                    k = s.index("}", j)
                    out.append(chr(int(s[j + 3:k], 16)))
                    j = k + 1
                elif e == "u":
                    out.append(chr(int(s[j + 2:j + 6], 16)))
                    j += 6
                elif e == "\n":
                    j += 2
                else:
                    out.append(e)
                    j += 2
            except ValueError:
                lit = False
                j += 2
        else:
            if q == "`" and c == "$" and s[j + 1:j + 2] == "{":
                lit = False
            out.append(c)
            j += 1
    return ("".join(out) if lit else None), j + 1


def _js_ws(s, i):
    n = len(s)
    while i < n:
        if s[i].isspace():
            i += 1
        elif s.startswith("//", i):
            j = s.find("\n", i)
            i = n if j < 0 else j
        elif s.startswith("/*", i):
            j = s.find("*/", i + 2)
            i = n if j < 0 else j + 2
        else:
            break
    return i


def _js_skip_value(s, i):
    """Index of the , or } ending the expression at s[i] (brackets and strings skipped)."""
    n, depth = len(s), 0
    while i < n:
        c = s[i]
        if c in "'\"`":
            i = _js_string(s, i)[1]
            continue
        if s.startswith(("//", "/*"), i):
            i = _js_ws(s, i)
            continue
        if c in ",}" and depth == 0:
            return i
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth = max(0, depth - 1)
        i += 1
    return n


def _js_object(s, i):
    """Properties of the object literal at s[i] whose value is a plain string literal."""
    props, n = {}, len(s)
    i += 1
    while True:
        i = _js_ws(s, i)
        if i >= n or s[i] == "}":
            return props
        if s[i] == ",":
            i += 1
            continue
        if s[i] in "'\"":
            key, i = _js_string(s, i)
        else:
            m = re.match(r"[A-Za-z_$][\w$]*", s[i:])
            if not m:
                i = _js_skip_value(s, i)
                continue
            key, i = m.group(), i + m.end()
        i = _js_ws(s, i)
        if i < n and s[i] == ":":
            i = _js_ws(s, i + 1)
            if i < n and s[i] in "'\"`":
                val, j = _js_string(s, i)
                k = _js_ws(s, j)
                if val is not None and (k >= n or s[k] in ",}"):
                    props[key] = val
                else:
                    props.pop(key, None)
                i = _js_skip_value(s, j)
                continue
            props.pop(key, None)
        i = _js_skip_value(s, i)


def _js_exec_cmds(code):
    """Literal cmd strings of `tools.exec_command({...})` calls in a JS cell. The cell is
    scanned, never evaluated: strings, comments and unused objects are not calls."""
    out, i, n = [], 0, len(code)
    while i < n:
        c = code[i]
        if c in "'\"`":
            i = _js_string(code, i)[1]
        elif code.startswith(("//", "/*"), i):
            i = max(_js_ws(code, i), i + 1)
        elif code.startswith("tools.exec_command", i) and (i == 0 or not (code[i - 1].isalnum() or code[i - 1] in "_$.")):
            j = _js_ws(code, i + 18)
            if j < n and code[j] == "(":
                j = _js_ws(code, j + 1)
                if j < n and code[j] == "{":
                    props = _js_object(code, j)
                    v = props.get("cmd", props.get("command"))
                    if isinstance(v, str):
                        out.append(v)
                    i = j
            i += 1
        else:
            i += 1
    return out


def _call_paths(name, args):
    """(path, needs expansion) for each file one tool call reads (may repeat; the caller counts
    each file once per call). Shell words arrive expanded already."""
    if not isinstance(name, str) or not isinstance(args, dict):
        return []
    out = []
    if name in READ_TOOLS:
        for k in READ_TOOLS[name]:
            v = args.get(k)
            out.extend((x, True) for x in (v if isinstance(v, list) else [v]))
    if name in SHELL_TOOLS:
        for k in SHELL_TOOLS[name]:
            v = args.get(k)
            if isinstance(v, list):   # argv form: ["bash", "-lc", "cat x"]
                v = " ".join(shlex.quote(str(x)) for x in v)
            if isinstance(v, str):
                out.extend((x, False) for x in _shell_paths(v))
    return out


def _json(v):
    if isinstance(v, str):
        try:
            return json.loads(v)
        except ValueError:
            return None
    return v


def _record_calls(fmt, rec):
    """(name, args) for each tool call in one transcript record."""
    calls = []
    if not isinstance(rec, dict):
        return calls
    if fmt in ("claude", "generic"):
        msg = rec.get("message")
        content = msg.get("content") if isinstance(msg, dict) else None
        if isinstance(content, list):
            for c in content:
                if isinstance(c, dict) and c.get("type") == "tool_use":
                    calls.append((c.get("name"), c.get("input")))
    elif fmt == "agy":
        tc = rec.get("tool_calls")
        for c in tc if isinstance(tc, list) else []:
            if isinstance(c, dict):
                calls.append((c.get("name"), c.get("args")))
    elif fmt == "codex":
        p = rec.get("payload")
        if rec.get("type") == "response_item" and isinstance(p, dict):
            if p.get("type") == "custom_tool_call" and p.get("name") == "exec" and isinstance(p.get("input"), str):
                # JS cell: tools.exec_command({cmd: "cat ...", ...})
                for cmd in _js_exec_cmds(p["input"]):
                    calls.append(("exec_command", {"cmd": cmd}))
            elif p.get("type") == "function_call":
                a = _json(p.get("arguments"))
                if isinstance(a, dict):
                    calls.append((p.get("name"), a))
    return calls


def reads(fmt, transcript_path, store_root):
    out = {}
    try:
        if not supported(fmt) or not store_root:
            return {}
        root = _expand(store_root).rstrip(os.sep)
        with open(transcript_path, errors="replace") as f:
            for line in f:
                try:
                    rec = json.loads(line)
                    found = []
                    for name, args in _record_calls(fmt, rec):
                        files = {_rel(p, root, x) for p, x in _call_paths(name, args)}
                        found.append(files - {None})
                except Exception:   # a record of the wrong shape is skipped, not fatal
                    continue
                for files in found:
                    for rel in files:
                        out[rel] = out.get(rel, 0) + 1
    except Exception:
        return {}
    return out
