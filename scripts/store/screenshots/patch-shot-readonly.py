import pathlib, sys
d = pathlib.Path(sys.argv[1])
p = d / 'StoreViews.swift'; t = p.read_text(); old = 'if disks.websiteVersionInstalled && !disks.hidesWebsiteNotice {'; assert old in t; p.write_text(t.replace(old, 'if false {'))
p = d / 'StoreDisks.swift'; t = p.read_text()
for old, new in [('let readOnly = values?.volumeIsReadOnly ?? mounted?.readOnly ?? true', 'let readOnly = true'),
                 ('? status?.reason.map(StoreReadOnlyText.explanation(token:)) ?? StoreReadOnlyText.unexplained', '? StoreReadOnlyText.explanation(token: "check:hibernated")')]:
    assert old in t, old; t = t.replace(old, new)
p.write_text(t)
