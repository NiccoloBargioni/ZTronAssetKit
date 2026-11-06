import sys, pathlib, importlib.util
spec = importlib.util.spec_from_file_location("m", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
root = pathlib.Path(sys.argv[2]); name = sys.argv[3]; mode = sys.argv[4]
f, old, new, flt = m.M[name]
p = root / f; s = p.read_text()
if mode == "filter": print(flt); sys.exit(0)
a, b = (old, new) if mode == "apply" else (new, old)
assert s.count(a) == 1, (name, mode, s.count(a))
p.write_text(s.replace(a, b)); print("ok", name, mode)
