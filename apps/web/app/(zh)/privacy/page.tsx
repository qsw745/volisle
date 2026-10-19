import type { Metadata } from 'next';
import { alternates } from '@/lib/i18n';
import { ArticlePage } from '@/components/ArticlePage';
import { release } from '@/lib/release';
export const metadata: Metadata = { title: '隐私说明', alternates: alternates('zh', '/privacy/') };
export default function Page() { return <ArticlePage title="文件留在硬盘。" lead="更新于 2026 年 10 月 6 日。盘屿没有账号、统计或遥测，核心功能完全在本机运行。">
<h2>应用读取什么</h2><p>为了显示和管理磁盘，盘屿从 macOS 读取卷名、文件系统、挂载位置、容量和设备标识，只在本机使用，不上传。盘屿不扫描文件内容，不收集管理员密码。</p>
<h2>BitLocker 密码与恢复密钥</h2><p>只用于本次解锁：在本机交给盘屿的后台组件算出解锁所需的密钥，再交给盘屿的文件系统扩展，不保存、不上传；锁定或推出后，内存中的密钥随即清除。</p>
<h2>本机保存什么</h2><p>外观、自动读写和更新等偏好；为安全恢复后台操作所需的磁盘连接标识和操作状态；以及写入时的恢复记录（位于盘屿文件系统扩展自己的容器内，正常推出后自动删除）。这些都不离开你的 Mac。</p>
<h2>联网</h2><p>只有检查和下载更新时会访问 qisw.top/volisle/updates/，请求中不含磁盘标识、卷名、文件路径或内容，也不上传系统概况。服务器能看到常规的 IP 地址、时间和客户端信息；更新目录不记录访问日志，仅保留服务器运行错误日志用于排障。</p>
<h2>官网</h2><p>本站是静态页面，没有统计脚本、广告、表单或第三方字体。</p>
<h2>诊断</h2><p>诊断只在你主动导出时生成，保存到你选择的位置，内容只包含系统版本、组件状态、磁盘数量和文件系统类型。</p>
<h2>运营者</h2><p>{release.contact ? `${release.publisher} · ${release.contact}` : `${release.publisher}。`}</p>
</ArticlePage>; }
