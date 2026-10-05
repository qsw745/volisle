import type { Metadata } from 'next';
import { DownloadPage } from '@/components/DownloadPage';
import { alternates } from '@/lib/i18n';
export const metadata: Metadata = { title: '下载盘屿', alternates: alternates('zh', '/download/') };
export default function Page() { return <DownloadPage locale="zh"/>; }
