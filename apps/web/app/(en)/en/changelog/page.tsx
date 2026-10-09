import type { Metadata } from 'next';
import { alternates } from '@/lib/i18n';
import { ArticlePage } from '@/components/ArticlePage';
export const metadata: Metadata = { title: 'Release Notes', alternates: alternates('en', '/changelog/') };
export default function Page() { return <ArticlePage locale="en" title="Every step, on the record." lead="Versions not marked as released have no public installer.">
<h2>0.8.4 · October 8, 2026</h2><ul>
<li>Faster “Open Files” after a copy: Volisle now confirms a copy by what the disk has actually written, usually in twenty-odd seconds instead of a fixed minute; slower drives get the time they need, and an unplug before that still rechecks and completes the copy when reconnected.</li>
<li>Fixed: while one disk was read-write, another disk connected meanwhile kept showing “processing” with every button greyed out. It now says it is waiting, and its files can be opened and browsed as usual.</li>
</ul>
<h2>0.8.3 · October 8, 2026</h2><ul>
<li>New: Recover on This Mac. For a disk unplugged from Windows without “Safely Remove Hardware”, click “Recover on This Mac…”: Volisle checks it read-only first, then completes the unfinished changes the way Windows would; if they can’t be replayed, it turns on writing only after confirming the disk is consistent and you agree to give up Windows’ last unfinished changes. Everything changed is backed up first, and the disk is put back if any step fails. When a Windows PC is at hand, ejecting the disk there is still the safest fix.</li>
<li>New: “Keep the Mac awake while copying” in Settings (on by default).</li>
<li>A redesigned installer window: drag Volisle to Applications to install.</li>
<li>Disks taken by another NTFS tool (TT NTFS, xntfs, macFUSE and others) now show which tool has them and three steps to hand them to Volisle.</li>
<li>“Check on This Mac” now also checks how disk space is allocated.</li>
<li>The background component is retried when it can’t be reached, and diagnostics include the background service’s state.</li>
</ul>
<h2>0.8.2 · October 7, 2026</h2><ul>
<li>New: runs on macOS 15.4 or later (previously 26.4). Automatic write access, copying, resuming after an unplug, recovery files, formatting and BitLocker disks were verified on macOS 15.6.1; physical USB drives on macOS 15 haven’t been tested yet, so please report any problems.</li>
<li>Fixed: files copied onto an NTFS disk by Volisle sometimes didn’t appear in Finder.</li>
<li>When a copy finishes, click Show in Finder to select the copied items.</li>
<li>With automatic write access turned off, an unfinished copy now turns writing back on for its disk and continues after the disk is plugged in again.</li>
<li>Pausing a copy no longer resets its progress; when resuming, one progress bar shows the check of what was already copied, then the rest.</li>
<li>If the same file keeps failing to read or write, automatic resuming stops and Volisle explains why instead of retrying endlessly.</li>
<li>When another NTFS tool (such as TT NTFS, macFUSE / NTFS-3G, Paragon or Tuxera) has taken a disk, Volisle now lists it, says which tool has it and how to hand it over, instead of saying nothing.</li>
<li>“Can’t write? Check why” and diagnostics now read the errors the drive itself reports, telling bad sectors apart from an unsteady cable, port or power supply.</li>
<li>Dialogs now follow the System Settings style; Volisle quits normally while the write check, diagnostics, copy or recovery windows are open; switching back to Volisle no longer refreshes everything.</li>
</ul>
<h2>0.8.0 · October 6, 2026</h2><ul>
<li>New: resumable copies. On a disk with write access, choose Copy to This Disk… (or drag items into the Volisle window). After a disconnection, ejection or app exit, Volisle checks the existing content before continuing once the disk is connected again and write access has been safely restored.</li>
<li>Before continuing, Volisle compares what is already on the disk with the originals block by block and carries on from where they match; files finished in the minute or so before an unplug are checked again, and anything rolled back is copied again. A file takes its name on the disk only once it’s complete, and a file it replaces stays intact until then. If a file can’t be read or the disk refuses a name, the copy pauses and you can skip that item.</li>
<li>Help now explains what to do if a disk was unplugged during a copy: when to choose Skip or Replace in Finder, and how to resume by file with rsync.</li>
<li>Fixed: after a disk was unplugged in the middle of a copy, some USB drives stayed read-only when connected again (“the file system extension didn’t turn on writing”). Volisle now recognizes partially written data from an interrupted write and restores the last consistent state before enabling write access when safety checks pass. If the checks fail, the disk stays read-only and Volisle explains why.</li>
<li>Fixed: if a write fails while you are pausing a copy, your pause choice is kept. Click Continue to resume after the disk recovers. Paused progress now explains the size of completed files and that unfinished content will be checked before continuing.</li>
<li>If this version cannot read the format of write recovery records, Volisle now explains the incompatibility, keeps the disk read-only and preserves the original records for recovery with a compatible version.</li>
<li>If a disk can’t be written to, select it and click “Can’t write? Check why” to check the background component, Full Disk Access, the file system extension, the disk itself and why the last attempt failed, with what to do for each; messages now also name the actual reason. Exported diagnostics include recent operation results and Volisle’s activity log with paths, names and identifiers removed, so a report shows where things stopped.</li>
</ul>
<h2>0.7.0 · October 6, 2026</h2><ul>
<li>Stable release: a full review fixed a set of rare problems that could leave a disk read-only for good, stuck, or impossible to eject. Updating is recommended for everyone.</li>
<li>File names now work both ways with Windows: names with ? : * &quot; &lt; &gt; | \ or ending in a space or period open and delete normally in Windows, and names written by other systems with accented letters or East Asian characters, which listed but wouldn’t open, now open.</li>
<li>After a disk read or write error while writing, Restore Read-Only now works and writing can be turned on again, instead of getting stuck verifying or failing to eject.</li>
<li>Check on This Mac no longer reports a read error (a bad sector, or an unstable cable or port) as damaged file records, and adds a line of technical details when a check doesn’t pass; it no longer clears the flag when Windows maintenance didn’t finish, and disks with directory junctions can now be checked.</li>
<li>Faster: large files read at about 100 MB/s and write at about 50 MB/s, folders with tens of thousands of files open at once, and deleting many files is dozens of times faster.</li>
<li>Copying files with the hidden attribute no longer stops partway; messages such as no space, name already exists, and folder not empty are more precise; new dot files are hidden in Windows too.</li>
<li>With a BitLocker disk unlocked, updates and quitting Volisle work normally, and BitLocker disks can be ejected from the menu bar; Erase selects the disk chosen in the sidebar and shows its size and device name.</li>
<li>Disks that can only be read (write-protected, not USB, or without a partition table) now say why; refreshing the disk list no longer turns writing back on for a disk you set to read-only; launching at login no longer opens the main window.</li>
</ul>
<h2>0.6.1 · October 5, 2026</h2><ul>
<li>Fixes a drive that was unplugged and quickly reconnected sometimes not getting write access, and sometimes disappearing from Finder until Volisle was reopened. Volisle now waits for macOS to finish mounting the drive first; if turning on writing still fails, the drive stays available read-only.</li>
</ul>
<h2>0.6.0 · October 5, 2026</h2><ul>
<li>New: BitLocker-encrypted drives can now be written to. Unlock with the password or 48-digit recovery key, then copy, change and delete files in Finder, with the same unplug protection as other NTFS drives. A drive that needs a check, comes from a hibernated Windows, or wasn’t ejected safely opens read-only, with the reason shown.</li>
<li>A regular NTFS drive and a BitLocker drive can be written to at the same time.</li>
<li>A BitLocker drive unplugged while unlocked can be unlocked again when reconnected.</li>
<li>When another disk is selected, the bottom bar names the disk that is read-write.</li>
</ul>
<h2>0.5.8 · October 5, 2026</h2><ul>
<li>Important fix: drives formatted by Windows 11 were marked as needing a check after Volisle wrote to them, so they came back read-only; if the drive was ejected soon after writing, files just written could be rolled back on the next connection. Please update.</li>
<li>Drives that already show “needs check” because of this recover on their own when reconnected after updating. If one stays read-only, choose “Check on This Mac…” once, or check it in Windows and eject it safely.</li>
</ul>
<h2>0.5.7 · October 5, 2026</h2><ul>
<li>Settings › About now has links to the website, help, feedback, and “Buy Me a Milk Tea”. The Help menu opens the help and feedback pages too.</li>
<li>New “Support Volisle” page on the website. Volisle stays free and open source; tips are optional and never unlock anything.</li>
</ul>
<h2>0.5.6 · October 5, 2026</h2><ul>
<li>Fixes the disk list and window contents sometimes shifting under the title bar and overlapping the window buttons (often after opening at login).</li>
<li>Clearer setup step 2: turn on “Volisle NTFS” in the File System Extensions list; you can ignore the “FSKit Modules” switch on the By App page. If the switch won’t turn on, the guide now says what to try.</li>
<li>When a disk is marked as needing a check, “Check on This Mac…” is now in the disk details and the More menu, and stays there after Volisle restarts.</li>
</ul>
<h2>0.5.5 · October 4, 2026</h2><ul>
<li>Fixes stale old content appearing in a file after unplugging mid-copy, caused by data lost from the drive’s own write cache. Volisle now keeps about 20 seconds of recovery records and rolls all of it back after an unplug; if you unplug without ejecting, copy anything from the last 20 seconds or so again.</li>
<li>Fixes a just-connected disk sometimes staying read-only when macOS was still mounting it. Volisle now retries shortly afterwards.</li>
</ul>
<h2>0.5.4 · October 4, 2026</h2><ul>
<li>Fixes a just-connected disk getting mounted twice—read-only by macOS and for writing by Volisle—which left “Volisle hasn’t confirmed the disk is writable” on screen and “Return to Read-Only” unable to finish.</li>
<li>Fixes a full disk refusing every change afterwards (even deleting files) and coming back read-only next time. Running out of space now just reports it; delete files to keep writing.</li>
<li>Fixes the bottom message bar covering the sidebar’s Settings button.</li>
<li>Note: testing showed that unplugging mid-copy can lose data still in the drive’s own write cache, leaving the file being copied incomplete or wrong. Eject before unplugging; the next version keeps more recovery records after an unplug.</li>
</ul>
<h2>0.5.3 · October 3, 2026</h2><ul>
<li>Fixes disks that stayed read-only on the Mac after a write was interrupted there (for example, unplugged without ejecting) and the disk was then used in Windows. Volisle now checks the disk as it is; if it’s marked as needing a check, use “Check on This Mac…” or check it in Windows. The leftover recovery records are no longer used to roll back, so nothing Windows wrote is overwritten.</li>
</ul>
<h2>0.5.2 · October 3, 2026</h2><ul>
<li>A new setup guide walks you through three steps on first launch: allow Volisle in the background, turn on its file system extension, and allow it to read disks. Each step has a button that opens the right System Settings page and ticks itself once the switch is on.</li>
<li>Volisle now checks that Full Disk Access is on. Before, setup could say it was complete without it, and the permission error only appeared once a disk was connected.</li>
<li>Fixes Volisle not quitting—and possibly holding up logout or shutdown—while the setup window is open.</li>
</ul>
<h2>0.5.1 · October 3, 2026</h2><ul>
<li>Faster large-file writes: copying large files to NTFS disks is about 60% faster (from about 25 MB/s to about 42 MB/s on a 2 TB USB drive). Automatic recovery after an interrupted write works as before.</li>
<li>When write access can’t be turned on, Volisle now says why and what to do, instead of only “couldn’t verify the current disk”.</li>
<li>Fixes used space showing as zero in Finder and Disk Utility while a disk is writable.</li>
<li>Diagnostics reports now include how disks are connected and the result of the last operation.</li>
</ul>
<h2>0.5.0 · September 30, 2026</h2><ul>
<li>Supports BitLocker-encrypted Windows disks: they appear in the sidebar as “BitLocker · Locked”. Unlock with the password or 48-digit recovery key to view and copy files in Finder, read-only; choose Lock or eject when you’re done.</li>
<li>Works with fully encrypted NTFS volumes from Windows 7 and later (XTS-AES or AES-CBC, 128 or 256-bit). Disks still being encrypted or decrypted, and system disks protected only by a TPM, aren’t supported yet.</li>
<li>The password is used only for that unlock and isn’t saved. Volisle never writes to BitLocker disks.</li>
</ul>
<h2>0.4.0 · September 29, 2026</h2><ul>
<li>New “Erase Disk…” (More menu): erase an external USB disk (GUID or MBR) or a single Windows data partition as NTFS, with write access turned on afterward. Internal disks, the startup disk, and disks with a mounted Mac volume aren’t offered.</li>
<li>Fixes “one or more items can’t be copied” when copying downloaded files to an NTFS disk.</li>
<li>Supports symbolic links, so app bundles such as macOS installers copy completely. On Windows these links appear as small system files that back up normally.</li>
<li>No Windows PC needed to lift read-only: when a disk is only marked as needing a check, choose “Check on This Mac…”. Volisle reads every file and folder record and clears the mark only if nothing is wrong; disks from a hibernated Windows or one that didn’t eject safely still need Windows. This isn’t the same as a full disk check in Windows.</li>
<li>Diagnostics reports show the actual version.</li>
</ul>
<h2>0.3.3 · September 28, 2026</h2><ul>
<li>Adds an English interface: Volisle follows your system language, showing English on English and other non-Chinese systems while Chinese systems stay in Chinese. The main window, Settings, menu bar, confirmations, messages and errors, and the diagnostics report are all translated.</li>
<li>The read-write engine and background component code are the same as in 0.3.2.</li>
</ul>
<h2>0.3.2 · September 27, 2026</h2><ul>
<li>The app name follows the system language: “盘屿” on Chinese systems and “Volisle” in English and other languages—consistent across Finder, the Dock, Launchpad, and the menu bar.</li>
<li>The file system extension likewise appears as “盘屿 NTFS” or “Volisle NTFS” in System Settings.</li>
<li>The interface was still Chinese-only at the time; the read-write engine and background component code were the same as in 0.3.1.</li>
</ul>
<h2>0.3.1 · September 27, 2026</h2><ul>
<li>The sidebar always shows the disk list; the collapse button was removed so content no longer jumps when the sidebar appears.</li>
<li>While another NTFS disk has write access, a second disk now explains that only one disk can be writable at a time, and that it turns writable automatically once the first is ejected.</li>
<li>The whole “NTFS Engine” row in Settings can be clicked to expand it.</li>
<li>The read-write engine and background component are the same as in 0.3.0.</li>
</ul>
<h2>0.3.0 · September 26, 2026 · First release</h2><ul>
<li>Connected NTFS disks are checked and made writable automatically, even with the window closed.</li>
<li>Edit and save directly from apps such as TextEdit, including replacing a file with the same name.</li>
<li>Every write is recorded: after unplugging or a crash, the disk returns to its last complete state the next time it connects.</li>
<li>A setup guide appears on first launch, with a direct link to the extension switch in System Settings.</li>
<li>Windows file permissions are preserved; files created on the Mac inherit their folder’s permissions.</li>
<li>Much faster writes on large drives (about 37 MB/s measured on a 2 TB drive).</li>
<li>If Windows didn’t eject safely, is hibernated, or the disk needs a check, the disk stays read-only with an explanation and what to do.</li>
<li>Windows system folders are hidden; the sidebar lists only NTFS disks; adds ⌘O to open in Finder, ⌘E to eject, and ⌘I for disk details.</li>
</ul>
<h2>0.2.0 · September 2026 · Not released</h2><ul><li>Connected the signed file system extension and background component, and verified reading and writing a 2 TB USB NTFS drive.</li><li>Added automatic updates, a menu bar item, and safe ejecting.</li></ul>
<h2>0.1.0 · September 2026 · Not released</h2><ul><li>Chose the NTFS engine and built the native interface and the first version of this website.</li></ul>
</ArticlePage>; }
