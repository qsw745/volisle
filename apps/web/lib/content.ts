import type { Locale } from './i18n';

type Row = { item: string; state: string; detail: string; limited?: boolean };
type Faq = { q: string; a: string };

/** `limited` marks states shown in the cautionary style (unsupported, unverified, partial). */
export const compatibility: Record<Locale, Row[]> = {
  zh: [
    { item: 'Apple 芯片 Mac · macOS 27.2', state: '已验证', detail: '完成安装、插入后自动读写、应用内保存、写入中直接拔线后自动恢复，以及与 Windows 的往返校验。' },
    { item: 'macOS 26.6', state: '部分验证', limited: true, detail: '在全新系统上完成下载安装、首次设置，以及磁盘镜像上的读写和异常中断恢复；尚未用实体 USB 硬盘验证。' },
    { item: 'macOS 26.4 – 27.1 其他版本', state: '未验证', limited: true, detail: '可以安装的最低版本为 macOS 26.4，其他版本尚未验证。' },
    { item: 'Intel Mac', state: '不支持', limited: true, detail: '安装包只包含 Apple 芯片版本。' },
    { item: '外接 USB NTFS 硬盘与 U 盘', state: '支持', detail: '新建、复制、编辑保存、重命名、移动、删除。插入后自动检查并开启读写。' },
    { item: '应用内编辑保存', state: '支持', detail: '“文本编辑”等常见应用的保存与同名替换。以文件夹形式保存的文稿（如 .pages、.rtfd）暂不支持覆盖保存。' },
    { item: 'Windows 文件权限', state: '保留', detail: 'Windows 设置的权限在 Mac 编辑后保持不变；在 Mac 新建的文件继承所在文件夹的权限。' },
    { item: 'Mac 多用户权限', state: '不区分', limited: true, detail: '与 macOS 使用 exFAT 磁盘时相同，Mac 上的各个用户都能读写盘内文件。请勿把它当作访问控制或加密。' },
    { item: '意外断开与异常退出', state: '自动恢复', detail: '下次连接时自动回到最后一个完整状态，可能丢失断开前几秒内尚未完成的写入。' },
    { item: 'Windows 未安全弹出、休眠或快速启动', state: '只读保护', detail: '为保护数据保持只读，并说明原因和处理方法。' },
    { item: '读写时睡眠唤醒', state: '支持', detail: '读写中合盖睡眠，唤醒后保持读写，无需重新连接。' },
    { item: '同时读写多块磁盘', state: '暂不支持', limited: true, detail: '同一时间为一块磁盘开启读写，其他磁盘保持只读；推出第一块后，下一块自动开启读写。' },
    { item: 'BitLocker 加密', state: '可读写', detail: '输入密码或 48 位恢复密钥解锁后可在 Finder 中读写；支持 Windows 7 起已完成加密的卷（XTS-AES、AES-CBC）。盘需要检查、来自休眠的 Windows 或没有安全弹出时自动以只读打开。' },
    { item: 'EFS 加密文件', state: '不支持', limited: true, detail: '不提供解密或写入。' },
    { item: '界面语言', state: '中文、英文', detail: '跟随系统语言：中文系统显示中文，英文及其他语言显示英文。' },
  ],
  en: [
    { item: 'Apple silicon Mac · macOS 27.2', state: 'Verified', detail: 'Installation, automatic write access on connect, saving from apps, automatic recovery after unplugging mid-write, and round trips with Windows.' },
    { item: 'macOS 26.6', state: 'Partly verified', limited: true, detail: 'Download, installation, and setup on a clean system, plus reading, writing, and interruption recovery on a disk image. Not yet verified with a physical USB drive.' },
    { item: 'Other versions, macOS 26.4 – 27.1', state: 'Not verified', limited: true, detail: 'Volisle installs on macOS 26.4 or later; other versions haven’t been verified yet.' },
    { item: 'Intel-based Mac', state: 'Not supported', limited: true, detail: 'The installer contains only the Apple silicon version.' },
    { item: 'External USB NTFS drives and flash drives', state: 'Supported', detail: 'Create, copy, edit and save, rename, move, and delete. Checked and made writable automatically when connected.' },
    { item: 'Saving from apps', state: 'Supported', detail: 'Saving and replace-in-place from common apps such as TextEdit. Documents saved as folders (such as .pages and .rtfd) can’t be overwritten yet.' },
    { item: 'Windows file permissions', state: 'Preserved', detail: 'Permissions set in Windows stay the same after editing on Mac; files created on Mac inherit their folder’s permissions.' },
    { item: 'Permissions between Mac users', state: 'Not separated', limited: true, detail: 'As with exFAT disks on macOS, every user on the Mac can read and write the files. Don’t rely on it for access control or encryption.' },
    { item: 'Unexpected disconnects and crashes', state: 'Recovers automatically', detail: 'The disk returns to its last complete state the next time it connects. Writes from the last few seconds before the disconnect may be lost.' },
    { item: 'Windows not ejected safely, hibernated, or Fast Startup', state: 'Read-only protection', detail: 'The disk stays read-only to protect your data, and Volisle explains why and what to do.' },
    { item: 'Sleep and wake during writes', state: 'Supported', detail: 'Close the lid while writing; write access stays on after waking, with no need to reconnect.' },
    { item: 'Writing to several disks at once', state: 'Not yet', limited: true, detail: 'One disk has write access at a time and others stay read-only; after you eject the first, the next one gets write access automatically.' },
    { item: 'BitLocker encryption', state: 'Read-write', detail: 'Unlock with the password or 48-digit recovery key, then read and write in Finder. Fully encrypted volumes from Windows 7 and later (XTS-AES, AES-CBC). Opens read-only if the disk needs a check, comes from a hibernated Windows, or wasn’t ejected safely.' },
    { item: 'EFS-encrypted files', state: 'Not supported', limited: true, detail: 'No decryption or writing.' },
    { item: 'Interface language', state: 'English, Chinese', detail: 'Follows your system language: Chinese systems show Chinese; English and other languages show English.' },
  ],
};

export const faqs: Record<Locale, Faq[]> = {
  zh: [
    { q: '盘屿收费吗？', a: '官网版免费，源码以 GNU GPL v2 开放。没有账号、订阅或内购。' },
    { q: '为什么我的 NTFS 磁盘是只读的？', a: '盘屿每次开启读写前都会检查磁盘。如果这块盘上次在 Windows 中没有安全弹出、Windows 处于休眠或“快速启动”，或者磁盘被标记为需要检查，盘屿会保持只读，并在窗口底部说明原因和处理方法。' },
    { q: '需要哪些授权？', a: '第一次使用时，在盘屿设置里启用文件系统扩展、允许后台组件，并为盘屿开启完全磁盘访问。之后插入磁盘即可使用，不需要每次输入密码，也无需关闭系统完整性保护（SIP）。' },
    { q: '哪些 Mac 可以使用？', a: '需要 Apple 芯片 Mac 和 macOS 26.4 或更高版本。目前在 macOS 27.2 上完成了实体硬盘的完整验证；macOS 26.6 上完成了安装和磁盘镜像读写验证；其他版本尚未验证。' },
    { q: '在 Windows 上没弹出就拔了盘，怎么办？', a: '插到 Mac 上仍能打开和复制文件，但盘屿会先保持只读，因为 Windows 还有没写完的改动，此时在 Mac 上写入可能损坏磁盘。拔盘那一刻 Windows 正在写的文件可能不完整，其他文件不受影响。处理方法：把盘插回任意一台 Windows 电脑，打开一次，再用“安全删除硬件”弹出，插回 Mac 就会自动开启读写；如果 Windows 提示磁盘有错误，先在“属性 → 工具 → 检查”中修复。都不需要格式化。暂时没有 Windows 电脑时，可以先把重要文件复制出来。如果盘有异响、无法识别或读取大量出错，请先停止写入，交给专业数据恢复工具或服务处理。' },
    { q: '没推出就拔线会怎样？', a: '盘屿会记录每次写入，下次连接时先恢复，再开启读写。移动硬盘自身的写入缓存断电会丢失，所以盘屿会把拔线前约 20 秒内的写入一并退回，回到确定已写进硬盘的状态；这段时间里拷贝的文件需要重新拷贝。请尽量先推出再拔线。' },
    { q: '是否支持加密磁盘？', a: 'BitLocker 加密的磁盘可以用密码或恢复密钥解锁后读写，和普通 NTFS 盘一样有拔线保护；EFS 加密文件暂不支持。盘屿不提供磁盘修复或数据恢复。' },
    { q: '如何推出和卸载？', a: '在盘屿或 Finder 中推出磁盘。如果提示磁盘正被使用，先关闭占用它的应用再试，盘屿不会强制推出。卸载时先推出所有磁盘，关闭“登录时启动盘屿”，在设置中移除后台组件，再退出并删除应用；完整步骤见“帮助”页的“卸载”。' },
  ],
  en: [
    { q: 'Does Volisle cost anything?', a: 'The website version is free, and the source code is available under the GNU GPL v2. There are no accounts, subscriptions, or in-app purchases.' },
    { q: 'Why is my NTFS disk read-only?', a: 'Volisle checks a disk every time before turning on write access. If the disk wasn’t ejected safely from Windows last time, Windows is hibernated or using Fast Startup, or the disk is marked as needing a check, Volisle keeps it read-only and explains why and what to do at the bottom of the window.' },
    { q: 'What permissions does it need?', a: 'The first time, in Volisle’s Settings, turn on the file system extension, allow the background component, and give Volisle Full Disk Access. After that, just connect a disk—no password each time, and no need to turn off System Integrity Protection (SIP).' },
    { q: 'Which Macs can use it?', a: 'A Mac with Apple silicon and macOS 26.4 or later. Full verification with a physical drive was done on macOS 27.2; on macOS 26.6, installation and reading and writing on a disk image were verified; other versions haven’t been verified yet.' },
    { q: 'I unplugged the disk in Windows without ejecting it. What now?', a: 'On the Mac you can still open and copy files, but Volisle keeps the disk read-only at first: Windows still has unfinished changes on it, and writing from the Mac now could damage the disk. A file Windows was writing at the moment you unplugged may be incomplete; other files aren’t affected. To fix it, connect the disk to any Windows PC, open it once, eject it with “Safely Remove Hardware”, then reconnect it to your Mac and write access turns on automatically. If Windows reports errors, repair them first in Properties → Tools → Check. No formatting is needed. If you don’t have a Windows PC handy, copy your important files off first. If the disk makes unusual noises, isn’t recognized, or has many read errors, stop writing to it and use a professional data recovery tool or service.' },
    { q: 'What happens if I unplug without ejecting?', a: 'Volisle records every write and recovers the disk before turning on writing again. A drive’s own write cache is lost when power is cut, so Volisle also rolls back writes from about the last 20 seconds before the unplug, returning to a state that is surely on the disk; copy anything from that time again. Eject before unplugging whenever you can.' },
    { q: 'Are encrypted disks supported?', a: 'BitLocker-encrypted disks can be unlocked with the password or recovery key and used read-write, with the same unplug protection as other NTFS disks. EFS-encrypted files aren’t supported. Volisle doesn’t repair disks or recover data.' },
    { q: 'How do I eject and uninstall?', a: 'Eject the disk in Volisle or Finder. If you’re told the disk is in use, quit the app using it and try again—Volisle never forces an eject. To uninstall, eject all disks, turn off “Open Volisle at login”, remove the background component in Settings, then quit and delete the app. See “Uninstall” on the Help page for the full steps.' },
  ],
};
