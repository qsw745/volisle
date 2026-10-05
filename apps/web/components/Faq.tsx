import { faqs } from '@/lib/content';
import type { Locale } from '@/lib/i18n';
export function Faq({ locale = 'zh' }: { locale?: Locale }) { return <div className="faq-list">{faqs[locale].map(item => <details key={item.q}><summary>{item.q}<span aria-hidden="true">+</span></summary><p>{item.a}</p></details>)}</div>; }
