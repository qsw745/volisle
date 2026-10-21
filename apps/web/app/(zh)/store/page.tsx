import type { Metadata } from 'next';
import Link from 'next/link';
import { alternates } from '@/lib/i18n';
import { ArticlePage } from '@/components/ArticlePage';
export const metadata: Metadata = { title: 'App Store 版帮助', alternates: alternates('zh', '/store/') };
export default function Page() { return <ArticlePage title="App Store 版帮助" lead="适用于从 Mac App Store 安装的“盘屿 - NTFS 磁盘读写”。官网下载的盘屿请看《帮助》。">
<h2>第一次使用</h2><ol className="timeline">
<li><strong>打开文件系统扩展</strong><span>打开盘屿，点“打开系统设置”，在“文件系统扩展”列表里打开“盘屿 NTFS”。列表在“系统设置 → 通用 → 登录项与扩展 → 文件系统扩展”。只需要做一次。</span></li>
<li><strong>接上磁盘</strong><span>回到盘屿，接上 NTFS 移动硬盘、U 盘或存储卡，它会出现在访达里，可以直接拷贝、修改和删除文件。打开扩展之前就接着的磁盘，推出后重新接上。</span></li>
<li><strong>推出</strong><span>用完在访达或盘屿里推出，再拔下磁盘。</span></li></ol>
<p>“文件系统扩展”列表里没有“盘屿 NTFS”时：确认盘屿在“应用程序”文件夹里，退出后重新打开；仍然没有，重新启动 Mac。</p>
<h2>磁盘是只读的</h2><p>打开盘屿，选中这块磁盘，会说明原因：</p><ul>
<li>设置了“默认只读”：在盘屿的设置里关掉，推出后重新接上。</li>
<li>来自休眠或开着“快速启动”的 Windows：在 Windows 里完全关机后再接上。</li>
<li>上次没有在 Windows 里安全弹出，或被标记为需要检查：接回 Windows 检查磁盘，安全弹出后再接回 Mac。</li>
<li>写保护开关打开了：检查磁盘、存储卡或读卡器上的开关。</li></ul>
<h2>更新盘屿前先推出磁盘</h2><p>盘屿更新时，macOS 会先结束它的文件系统扩展。这时正在读写的磁盘会像被拔下一样中断：盘屿下次挂载时会自动恢复到中断前的一致状态，但最后约 20 秒写入的内容会退回。</p><ul>
<li>更新前先推出磁盘。</li>
<li>App Store 默认自动更新。经常长时间读写磁盘的话，可以在“App Store → 设置”里关闭自动更新，用完磁盘再手动更新。</li>
<li>盘屿提示“上次读写这块盘时被中断了”时，请检查最近拷贝或修改的文件，没有的重新拷贝一次。</li></ul>
<h2>磁盘工具的“急救”报失败</h2><p>对盘屿读写的 NTFS 磁盘运行“急救”，会提示无法检查或修复。这是因为 macOS 把这类分区当成 FAT 格式去检查；检查程序认不出 NTFS 就停下了，不会改动磁盘。盘屿不在 Mac 上检查或修复 NTFS，需要检查时请把磁盘接到 Windows 上运行磁盘检查。</p>
<h2>不支持的</h2><p>格式化磁盘、BitLocker 加密的磁盘，以及在 Mac 上修复 NTFS 磁盘。</p>
<h2>和官网版的关系</h2><p>两个版本只用一个。同时使用时，磁盘可能被另一个版本接走，出现推出失败。不用官网版的话，先在它的设置里移除后台组件，再把它移到废纸篓。</p>
<h2>反馈与源码</h2><p>遇到问题请到 <a className="text-link" href="https://github.com/qsw745/volisle/issues">反馈页</a> 提 issue，写上系统版本和磁盘型号。盘屿是自由软件（GNU GPL v2），NTFS 读写使用 NTFS-3G，源代码在 <a className="text-link" href="https://github.com/qsw745/volisle">GitHub</a>。</p>
<p className="article-links"><Link className="text-link" href="/privacy/">隐私说明</Link><Link className="text-link" href="/help/">官网版帮助</Link></p>
</ArticlePage>; }
