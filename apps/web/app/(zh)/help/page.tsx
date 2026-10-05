import type { Metadata } from 'next';
import { alternates } from '@/lib/i18n';
import { ArticlePage } from '@/components/ArticlePage';
import { Faq } from '@/components/Faq';
export const metadata: Metadata = { title: '帮助', alternates: alternates('zh', '/help/') };
export default function Page() { return <ArticlePage title="连接，然后开始。" lead="第一次设置之后，就只剩插上和推出。">
<h2>第一次使用</h2><ol className="timeline">
<li><strong>跟着向导完成设置</strong><span>第一次打开盘屿会弹出设置向导，共三步：允许盘屿在后台运行、启用盘屿的文件系统扩展（“文件系统扩展”列表里的“盘屿 NTFS”）、允许盘屿读取磁盘（完全磁盘访问）。每一步点按钮会直接打开对应的系统设置页面，按提示打开开关即可，打开后向导会自动打勾。中途关掉也没关系，可以在设置的“首次使用”中继续。</span></li>
<li><strong>插入磁盘</strong><span>插入 NTFS 移动硬盘或 U 盘。盘屿在后台检查，通过后自动开启读写，侧栏会显示“可读写”。</span></li>
<li><strong>照常使用</strong><span>在 Finder 和其他应用里新建、编辑、保存、移动或删除文件。</span></li>
<li><strong>推出</strong><span>在盘屿或 Finder 中推出后再拔线。提示磁盘正被使用时，先关闭占用它的应用。</span></li></ol>
<h2>磁盘只读了怎么办</h2><p>看窗口底部的提示，按提示处理即可：</p><ul>
<li><strong>窗口顶部提示“还差一步”，文件系统扩展还没打开</strong>：打开“系统设置 → 通用 → 登录项与扩展 → 文件系统扩展”，打开“盘屿 NTFS”右边的开关。“按 App”页面里盘屿下面的“FSKit Modules”开关不用管，打不开也没关系。不需要重启，打开后把磁盘拔下再插上，或点盘屿右上角的刷新。</li>
<li><strong>上次在 Windows 中没有安全弹出</strong>：把磁盘接回 Windows，打开一次，然后用任务栏的“安全删除硬件”弹出，再插回 Mac。</li>
<li><strong>Windows 处于休眠或“快速启动”</strong>：在那台 Windows 电脑上完全关机后再插回 Mac。</li>
<li><strong>磁盘需要检查</strong>：在 Windows 中打开磁盘属性 → 工具 → 检查，完成后安全弹出。没有 Windows 时，可点提示旁的“在 Mac 上检查…”：盘屿只读检查全部文件和文件夹记录，没有发现问题才清除标记并开启读写。它不等同于 Windows 的完整磁盘检查，重要且没有备份的数据建议优先在 Windows 中检查。</li></ul>
<p>另外两种提示：</p><ul>
<li><strong>没能以读写方式挂载</strong>：重启 Mac 后重新插入。仍然出现时，在设置 → 支持中导出诊断并通过下方反馈页告诉我们。</li>
<li><strong>文件系统扩展没有开启写入</strong>：检查磁盘或读卡器的写保护开关；如果这块盘上次写入时被直接拔掉，接回 Windows 打开一次并安全弹出后再插回。</li></ul>
<p>如果是在 Mac 上写入时意外断开，盘屿会在下次连接时自动恢复，无需处理。</p>
<h2 id="erase">抹掉为 NTFS</h2><p>在右上角“更多”菜单中选择“抹掉磁盘…”，选择外接 USB 磁盘，再选择抹掉整块磁盘（GUID 或 MBR 分区表）或单个 Windows 数据分区，输入名称后确认。抹掉会删除全部数据且无法撤销；内置盘、系统盘和挂着 Mac 卷的磁盘不会出现在可选列表里。完成后可在 Windows 和 Mac 上读写。</p>
<h2 id="bitlocker">BitLocker 加密的磁盘</h2><p>插入后，侧栏会显示“BitLocker · 已锁定”。选中它，输入密码，或切换到“恢复密钥”输入 48 位数字，点“解锁”。解锁后自动打开 Finder，可以像普通磁盘一样拷贝、修改和删除文件。用完先点“锁定”或在 Finder 中推出，再拔线；直接拔线的话，下次解锁会先撤回最后几秒的写入。如果盘需要检查、来自休眠的 Windows 或上次没有安全弹出，会以只读方式打开，并说明原因。恢复密钥通常保存在你的 Microsoft 账户（aka.ms/myrecoverykey）、打印件或开启 BitLocker 时保存的文件里。密码只用于本次解锁，不会保存。正在加密或解密中的磁盘请等 Windows 完成后再试。</p>
<h2>常见问题</h2><Faq/>
<h2>导出诊断</h2><p>在设置 → 支持中选择“导出诊断…”。报告只包含系统与组件状态、磁盘数量和文件系统类型，不含卷名、完整路径、磁盘标识或文件内容。</p>
<h2 id="feedback">反馈问题</h2><p>遇到问题或有建议，可以在 <a className="inline-link" href="https://github.com/qsw745/volisle-feedback/issues/new/choose">GitHub 反馈页</a>提交（需要 GitHub 账号）。请写明 macOS 版本、盘屿版本和窗口里的提示；附上导出的诊断报告最有帮助。提交前请检查一遍，不要贴出卷名、文件路径等个人信息。</p>
<h2>更新</h2><p>盘屿会自动检查更新，也可以在设置中手动检查。安装更新前会先安全结束磁盘读写，磁盘正被使用时会等待。</p>
<h2 id="uninstall">卸载</h2><ol className="timeline">
<li><strong>推出磁盘</strong><span>在盘屿或 Finder 中推出所有 NTFS 磁盘。</span></li>
<li><strong>关闭登录启动</strong><span>打开设置（⌘,），在“通用”中关闭“登录时启动盘屿”。</span></li>
<li><strong>移除组件</strong><span>在设置 → 支持中展开“NTFS 引擎”，点“移除组件”，看到后台组件显示“尚未设置”即可。</span></li>
<li><strong>删除应用</strong><span>退出盘屿（⌘Q），把“应用程序”中的“盘屿”拖到废纸篓。</span></li></ol>
<p>完成以上步骤后，盘屿不会再在后台运行，文件系统扩展也会从系统设置中消失。磁盘上的文件不受影响，NTFS 磁盘之后仍可由 macOS 以只读方式打开。</p>
<h3>彻底清除（可选）</h3>
<p>系统会保留几个很小的设置和缓存文件（合计不到 1 MB），不影响使用。如需一并删除，请先确认每块 NTFS 磁盘最近一次都是正常推出的：写入中断后的恢复记录就保存在其中，删除后将无法再自动恢复。然后在 Finder 中按 ⇧⌘G，逐个前往并删除：</p>
<ul><li><code>~/Library/Containers/top.qisw.volisle.filesystem</code></li><li><code>~/Library/Application Scripts/top.qisw.volisle.filesystem</code></li><li><code>~/Library/Preferences/top.qisw.volisle.plist</code></li><li><code>~/Library/Caches/top.qisw.volisle</code></li><li><code>~/Library/HTTPStorages/top.qisw.volisle</code></li></ul>
<p>后台组件还在系统目录中留下一个空的锁文件，可在“终端”中运行以下命令删除（需要输入管理员密码）：</p>
<p><code>sudo rm -r /private/var/db/volisle</code></p>
</ArticlePage>; }
