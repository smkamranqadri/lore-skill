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
SEPARATORS = {"&&", "||", ";", "|", "&", ";;", "|&"}
REDIRECTS = {">", ">>", "<", "<<", "<<<", ">&", "&>", "2>", "2>>"}
WRAPPERS = {"sudo", "env", "command", "time", "nice", "exec"}
SHELLS = {"bash", "sh", "zsh"}
CODEX_CMD = re.compile(r'\b(?:cmd|command)\s*:\s*("(?:[^"\\]|\\.)*")')


def supported(fmt):
    return fmt in FORMATS


def _expand(p):
    return os.path.realpath(os.path.expandvars(os.path.expanduser(p)))


def _rel(path, root):
    """`path` relative to `root` with "/", or None unless it is a .md file in the store
    and not under .lore/."""
    if not isinstance(path, str) or not path or not path.endswith(".md"):
        return None
    if not (path.startswith(("/", "~", "$")) or path.startswith("${")):
        return None
    full = _expand(path)
    if not full.startswith(root + os.sep):
        return None
    rel = full[len(root) + 1:]
    if ".lore" in rel.split(os.sep):
        return None
    return rel.replace(os.sep, "/")


def _segments(cmd, depth=0):
    """Token lists of each simple command in a shell string, redirect targets dropped."""
    cmd = cmd.split("<<", 1)[0]   # a heredoc body is text, not commands
    try:
        lex = shlex.shlex(cmd, posix=True, punctuation_chars=True)
        lex.whitespace_split = True
        toks = list(lex)
    except ValueError:
        return []
    segs, cur, skip = [], [], False
    for t in toks:
        if t in SEPARATORS or t == "\n":
            segs.append(cur)
            cur, skip = [], False
        elif t in REDIRECTS:
            skip = True
        elif skip:
            skip = False
        else:
            cur.append(t)
    segs.append(cur)
    out = []
    for s in segs:
        while s and (s[0] in WRAPPERS or re.match(r"^\w+=", s[0])):
            s = s[1:]
        if s and os.path.basename(s[0]) in SHELLS and depth < 3:
            if "-c" in s or "-lc" in s:
                i = s.index("-c") if "-c" in s else s.index("-lc")
                if i + 1 < len(s):
                    out.extend(_segments(s[i + 1], depth + 1))
                continue
        if s:
            out.append(s)
    return out


def _shell_paths(cmd):
    paths = []
    for s in _segments(cmd):
        name = os.path.basename(s[0])
        if name not in READ_CMDS:
            continue
        args = s[1:]
        if name in PATTERN_CMDS and not any(a == "-e" or a.startswith("--regexp") for a in args):
            for i, a in enumerate(args):
                if not a.startswith("-"):
                    args = args[:i] + args[i + 1:]
                    break
        paths.extend(a for a in args if not a.startswith("-"))
    return paths


def _call_paths(name, args):
    """Paths one tool call reads (may repeat; the caller counts each file once per call)."""
    if not isinstance(name, str) or not isinstance(args, dict):
        return []
    out = []
    if name in READ_TOOLS:
        for k in READ_TOOLS[name]:
            v = args.get(k)
            out.extend(v if isinstance(v, list) else [v])
    if name in SHELL_TOOLS:
        for k in SHELL_TOOLS[name]:
            v = args.get(k)
            if isinstance(v, list):   # argv form: ["bash", "-lc", "cat x"]
                v = " ".join(shlex.quote(str(x)) for x in v)
            if isinstance(v, str):
                out.extend(_shell_paths(v))
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
        for c in rec.get("tool_calls") or []:
            if isinstance(c, dict):
                calls.append((c.get("name"), c.get("args")))
    elif fmt == "codex":
        p = rec.get("payload")
        if rec.get("type") == "response_item" and isinstance(p, dict):
            if p.get("type") == "custom_tool_call" and isinstance(p.get("input"), str):
                # JS cell: tools.exec_command({cmd: "cat ...", ...})
                for m in CODEX_CMD.finditer(p["input"]):
                    try:
                        calls.append(("exec_command", {"cmd": json.loads(m.group(1))}))
                    except ValueError:
                        pass
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
                except ValueError:
                    continue
                for name, args in _record_calls(fmt, rec):
                    files = {_rel(p, root) for p in _call_paths(name, args)}
                    for rel in files - {None}:
                        out[rel] = out.get(rel, 0) + 1
    except Exception:
        return {}
    return out
