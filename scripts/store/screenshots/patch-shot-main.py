import pathlib, sys
p = pathlib.Path(sys.argv[1]) / 'StoreViews.swift'; t = p.read_text()
old = 'if disks.websiteVersionInstalled && !disks.hidesWebsiteNotice {'; assert old in t
p.write_text(t.replace(old, 'if false {'))
