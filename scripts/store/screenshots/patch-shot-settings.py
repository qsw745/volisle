import pathlib, sys
p = pathlib.Path(sys.argv[1]) / 'StoreDisks.swift'; t = p.read_text()
old = 'preferReadOnly = chosen ?? false'; assert old in t
p.write_text(t.replace(old, 'preferReadOnly = true'))
