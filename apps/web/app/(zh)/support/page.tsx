import type { Metadata } from 'next';
import Link from 'next/link';
import { alternates } from '@/lib/i18n';
import { ArticlePage } from '@/components/ArticlePage';
import { SupportCodes } from '@/components/SupportCodes';
export const metadata: Metadata = { title: '支持盘屿', alternates: alternates('zh', '/support/') };
export default function Page() { return <ArticlePage title="支持盘屿" lead="盘屿永久免费、开源，没有账号、内购和订阅。觉得好用，可以请作者喝杯奶茶。">
<SupportCodes/>
<h2>先说清楚</h2><ul><li>赞助全凭自愿，金额随意。赞助与否，功能完全一样，以后也不会因为没赞助而限制任何功能。</li><li>这是作者个人的微信赞赏码，钱直接到作者本人账户，用于开发者账号年费、服务器和测试硬盘。</li><li>赞助不是购买，不提供发票，也不附带技术支持承诺。遇到问题请到 <a className="text-link" href="https://github.com/qsw745/volisle-feedback/issues">反馈页</a> 提 issue，赞助过的和没赞助过的一视同仁。</li></ul>
<h2>不花钱也能帮忙</h2><ul><li>把盘屿推荐给同样被 NTFS 硬盘困扰的朋友。</li><li>遇到问题时导出诊断、提 issue，告诉我们你的系统版本和硬盘型号。</li><li>在小红书、知乎、B 站写写你的使用体验。</li></ul>
<p className="article-links"><Link className="text-link" href="/download/">下载盘屿</Link><Link className="text-link" href="/help/">帮助</Link></p>
</ArticlePage>; }
