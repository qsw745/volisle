import Link from 'next/link';
import { localePath, ui, type Locale } from '@/lib/i18n';
export function ArticlePage({ title, lead, children, locale = 'zh' }: { title: string; lead: string; children: React.ReactNode; locale?: Locale }) {
  return <main id="main" className="article-page"><Link className="back" href={localePath(locale, '/')}>{ui[locale].back}</Link><h1>{title}</h1><p className="lead">{lead}</p><div className="article-body">{children}</div></main>;
}
