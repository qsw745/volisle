import type { Metadata } from 'next';
import { alternates } from '@/lib/i18n';
import { ArticlePage } from '@/components/ArticlePage';
export const metadata: Metadata = { title: '许可与条款', alternates: alternates('zh', '/terms/') };
export default function Page() { return <ArticlePage title="免费，开源，如实说明。" lead="2026 年 9 月 25 日。">
<h2>许可</h2><p>盘屿源码以 GNU GPL v2 发布。NTFS 引擎基于 NTFS-3G（GPL-2.0-or-later），自动更新使用 Sparkle（BSD 许可）。每个安装包都提供完整对应源码、修改记录和构建脚本，第三方许可声明随应用一同分发。</p>
<h2>无担保</h2><p>按 GPL v2 的约定，本软件“按原样”提供，不附带任何明示或暗示的担保。盘屿会在检查不通过时保持只读、在异常中断后自动恢复，但任何软件都不能替代备份。请为重要数据保留独立备份。</p>
<h2>不包含的功能</h2><p>盘屿不提供磁盘修复、分区调整、数据恢复或云同步。“抹掉磁盘”会删除所选磁盘或分区上的全部数据，且无法撤销。</p>
<h2>名称与标志</h2><p>“盘屿”“Volisle”名称和标志不随源码许可授予商标权。</p>
</ArticlePage>; }
