# Generates ios_bridge/src/methods.rs from the repo's generated Python API and mediasrv's allow-list.
import re, sys
root = sys.argv[1]
gen = open(f"{root}/out/pylib/anki/_backend_generated.py", encoding="utf8").read()
pairs = re.findall(r"def (\w+)\(self[^\n]*\n(?:[^\n]*\n)*?\s+raw_bytes = self\._run_command\((\d+), (\d+),", gen)
seen = {}
for n, s, m in pairs:
    seen.setdefault(n.removesuffix("_raw"), (s, m))
src = open(f"{root}/qt/aqt/mediasrv.py", encoding="utf8").read()
body = re.search(r"exposed_backend_list = \[(.*?)\n\]", src, re.S).group(1)
names = re.findall(r'"(\w+)"', body)
camel = lambda n: (p := n.split("_"))[0] + "".join(x.capitalize() for x in p[1:])
missing = [n for n in names if n not in seen]
assert not missing, missing
with open(f"{root}/ios_bridge/src/methods.rs", "w", encoding="utf8") as f:
    f.write("pub const METHODS: &[(&str, u32, u32)] = &[\n")
    for n, (s, m) in sorted(seen.items()):
        f.write(f'    ("{n}", {s}, {m}),\n')
    f.write("];\npub const EXPOSED: &[&str] = &[\n")
    for n in names:
        f.write(f'    "{camel(n)}",\n')
    f.write("];\n")
print(len(seen), "methods,", len(names), "exposed")
