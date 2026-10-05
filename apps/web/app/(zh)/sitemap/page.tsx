import type { Metadata } from 'next';
import { alternates } from '@/lib/i18n';
import Link from 'next/link';
import { ArticlePage } from '@/components/ArticlePage';
export const metadata: Metadata = { title: '站点地图', alternates: alternates('zh', '/sitemap/') };
export default function Page() { return <ArticlePage title="站点地图" lead="本站全部页面。"><ul className="sitemap-list">{[['/','首页'],['/download/','下载'],['/compatibility/','兼容性'],['/help/','帮助'],['/changelog/','更新日志'],['/privacy/','隐私说明'],['/terms/','许可与条款'],['/support/','支持盘屿'],['/en/','English']].map(([href,title]) => <li key={href}><Link className="text-link" href={href}>{title}</Link></li>)}</ul></ArticlePage>; }
