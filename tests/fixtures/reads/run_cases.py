"""Case runner for tests/test-reads.sh: shell, Codex JS, malformed-record and symlink cases.
Usage: run_cases.py <scripts dir> <fixtures dir> <store root>. Exits 1 and prints each miss."""
import json
import os
import sys
import tempfile

sys.path.insert(0, sys.argv[1])
import lore_reads

fx, root = sys.argv[2], sys.argv[3]
tmp = tempfile.mkdtemp()
bad = []
count = 0


def run(fmt, lines, want, label, store=root):
    global count
    count += 1
    path = os.path.join(tmp, "t.jsonl")
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")
    got = lore_reads.reads(fmt, path, store)
    if got != want:
        bad.append("%s: got %r, wanted %r" % (label, got, want))


for c in json.load(open(os.path.join(fx, "shell-cases.json"))):
    cmd = c["cmd"].replace("<root>", root)
    rec = {"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "Bash", "input": {"command": cmd}}]}}
    run("claude", [json.dumps(rec)], c["want"], "shell " + repr(c["cmd"]))

for c in json.load(open(os.path.join(fx, "codex-cases.json"))):
    rec = {"type": "response_item", "payload": {"type": "custom_tool_call", "name": c["tool"], "input": c["input"].replace("<root>", root)}}
    run("codex", [json.dumps(rec)], c["want"], "codex " + c["name"])

for fmt, name, want in (("agy", "agy-malformed.jsonl", {"read.md": 2}), ("claude", "claude-malformed.jsonl", {"read.md": 3})):
    lines = open(os.path.join(fx, name)).read().replace("<root>", root).splitlines()
    run(fmt, lines, want, name)

# symlinks: the returned identity must be a .md file inside the store, outside .lore
st = os.path.join(tmp, "store")
os.makedirs(os.path.join(st, ".lore"))
os.makedirs(os.path.join(tmp, "outside"))
for name in ("topic.txt", "real.md", ".lore/state.md"):
    open(os.path.join(st, name), "w").write("x")
open(os.path.join(tmp, "outside", "secret.md"), "w").write("x")
os.symlink("topic.txt", os.path.join(st, "suffix-alias.md"))
os.symlink("real.md", os.path.join(st, "alias.md"))
os.symlink(os.path.join(tmp, "outside", "secret.md"), os.path.join(st, "escape.md"))
os.symlink(".lore/state.md", os.path.join(st, "meta.md"))
for name, want in (("suffix-alias.md", {}), ("alias.md", {"real.md": 1}), ("escape.md", {}), ("meta.md", {})):
    rec = {"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "Read", "input": {"file_path": os.path.join(st, name)}}]}}
    run("claude", [json.dumps(rec)], want, "symlink " + name, store=st)

for b in bad:
    print("FAIL:", b, file=sys.stderr)
if not bad:
    print("%d case checks" % count)
sys.exit(1 if bad else 0)
