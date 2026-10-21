import type { Metadata } from 'next';
import Link from 'next/link';
import { alternates } from '@/lib/i18n';
import { ArticlePage } from '@/components/ArticlePage';
export const metadata: Metadata = { title: 'App Store Version Help', alternates: alternates('en', '/store/') };
export default function Page() { return <ArticlePage locale="en" title="App Store version help" lead="For Volisle installed from the Mac App Store. If you downloaded Volisle from this website, see Help.">
<h2>First use</h2><ol className="timeline">
<li><strong>Turn on the file system extension</strong><span>Open Volisle, click Open System Settings, and turn on “Volisle NTFS” in the File System Extensions list. It’s in System Settings → General → Login Items & Extensions → File System Extensions. You only do this once.</span></li>
<li><strong>Connect a disk</strong><span>Back in Volisle, connect an NTFS external drive, USB stick or memory card. It appears in Finder, ready to copy, change and delete files. A disk that was connected before you turned on the extension needs to be ejected and connected again.</span></li>
<li><strong>Eject</strong><span>When you’re done, eject the disk in Finder or Volisle before unplugging it.</span></li></ol>
<p>If “Volisle NTFS” isn’t in the File System Extensions list, make sure Volisle is in the Applications folder, quit it and open it again. If it’s still missing, restart the Mac.</p>
<h2>The disk is read-only</h2><p>Open Volisle and select the disk to see why:</p><ul>
<li>Read-Only by Default is on: turn it off in Volisle’s settings, then eject the disk and connect it again.</li>
<li>It comes from a Windows PC that’s hibernated or uses Fast Startup: shut Windows down completely, then connect the disk again.</li>
<li>It wasn’t ejected safely from Windows, or it’s marked as needing a check: connect it to Windows, check the disk there, eject it safely, then connect it to the Mac again.</li>
<li>A write-protect switch is on: check the disk, memory card or card reader.</li></ul>
<h2>Eject disks before updating Volisle</h2><p>When Volisle is updated, macOS first ends its file system extension. A disk it’s reading or writing is interrupted as if it were unplugged: the next time it’s mounted, Volisle recovers it to the consistent state it had before, but what was written in the last 20 seconds or so is undone.</p><ul>
<li>Eject your disks before you update.</li>
<li>The App Store updates apps automatically by default. If you often use disks for long stretches, you can turn off automatic updates in App Store → Settings and update by hand once you’re done with your disks.</li>
<li>If Volisle says reading and writing this disk was interrupted last time, check the files you copied or changed most recently, and copy again any that are missing.</li></ul>
<h2>Disk Utility First Aid reports a failure</h2><p>Running First Aid on an NTFS disk that Volisle reads and writes reports that the disk couldn’t be checked or repaired. macOS checks this kind of partition as if it were FAT; the checker stops when it sees NTFS and doesn’t change the disk. Volisle doesn’t check or repair NTFS on the Mac. To check a disk, run a disk check on a Windows PC.</p>
<h2>Not supported</h2><p>Formatting disks, BitLocker-encrypted disks, and repairing NTFS disks on the Mac.</p>
<h2>The website version</h2><p>Use only one of the two versions. With both in use, a disk may be taken over by the other version and then fail to eject. If you no longer use the website version, remove its background component in its settings, then move it to the Trash.</p>
<h2>Feedback and source code</h2><p>Report problems on the <a className="text-link" href="https://github.com/qsw745/volisle/issues">feedback page</a>, with your macOS version and disk model. Volisle is free software (GNU GPL v2) and uses NTFS-3G for NTFS; the source code is on <a className="text-link" href="https://github.com/qsw745/volisle">GitHub</a>.</p>
<p className="article-links"><Link className="text-link" href="/en/privacy/">Privacy</Link><Link className="text-link" href="/en/help/">Help for the website version</Link></p>
</ArticlePage>; }
