import type { Metadata } from 'next';
import Link from 'next/link';
import { alternates } from '@/lib/i18n';
import { ArticlePage } from '@/components/ArticlePage';
export const metadata: Metadata = { title: 'Site Map', alternates: alternates('en', '/sitemap/') };
export default function Page() { return <ArticlePage locale="en" title="Site Map" lead="Every page on this site."><ul className="sitemap-list">{[['/en/','Home'],['/en/download/','Download'],['/en/compatibility/','Compatibility'],['/en/help/','Help'],['/en/changelog/','Release Notes'],['/en/privacy/','Privacy'],['/en/terms/','License and Terms'],['/en/support/','Support Volisle'],['/','中文']].map(([href,title]) => <li key={href}><Link className="text-link" href={href}>{title}</Link></li>)}</ul></ArticlePage>; }
