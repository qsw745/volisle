import type { Metadata } from 'next';
import Link from 'next/link';
import './globals.css';
export const metadata: Metadata = { title: '页面不存在 · Page not found · 盘屿 Volisle', robots: { index: false } };
/** Unmatched URLs in either language land here, outside both root layouts. */
export default function GlobalNotFound() {
  return <html lang="zh-CN"><body><main id="main" className="container not-found">
    <h1>这座小岛，还没有路径。</h1><p>页面不存在，或地址已经改变。</p>
    <p lang="en">This page doesn’t exist, or its address has changed.</p>
    <p><Link className="button primary" href="/">返回盘屿首页</Link> <Link className="text-link" href="/en/" lang="en" hrefLang="en">Volisle home <span aria-hidden="true">›</span></Link></p>
  </main></body></html>;
}
