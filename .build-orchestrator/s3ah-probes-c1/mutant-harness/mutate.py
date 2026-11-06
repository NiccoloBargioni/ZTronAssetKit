import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path).read()
assert text.count(old) == 1, (path, old, text.count(old))
open(path, 'w').write(text.replace(old, new))
