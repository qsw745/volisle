import type { Metadata } from 'next';
import Link from 'next/link';
import { alternates } from '@/lib/i18n';
import { ArticlePage } from '@/components/ArticlePage';
import { SupportCodes } from '@/components/SupportCodes';
export const metadata: Metadata = { title: 'Support Volisle', alternates: alternates('en', '/support/') };
export default function Page() { return <ArticlePage locale="en" title="Support Volisle" lead="Volisle is free and open source forever, with no account, in-app purchases, or subscription. If it helps you, you can buy the author a milk tea.">
<SupportCodes locale="en"/>
<h2>To be clear</h2><ul><li>Donations are entirely voluntary, in any amount. Every feature is the same whether you donate or not, and nothing will ever be limited for people who don’t.</li><li>This is the author’s personal WeChat reward code. Money goes straight to the author and covers the developer account, the server, and test drives.</li><li>A donation isn’t a purchase: there’s no invoice and no support commitment. If something goes wrong, open an issue on the <a className="text-link" href="https://github.com/qsw745/volisle-feedback/issues">feedback page</a>. Everyone gets the same help.</li></ul>
<h2>Other ways to help</h2><ul><li>Tell a friend who’s stuck with a read-only NTFS drive.</li><li>When something breaks, export diagnostics and open an issue with your macOS version and drive model.</li><li>Write about your experience with Volisle.</li></ul>
<p className="article-links"><Link className="text-link" href="/en/download/">Download Volisle</Link><Link className="text-link" href="/en/help/">Help</Link></p>
</ArticlePage>; }
