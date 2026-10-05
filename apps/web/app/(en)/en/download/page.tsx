import type { Metadata } from 'next';
import { DownloadPage } from '@/components/DownloadPage';
import { alternates } from '@/lib/i18n';
export const metadata: Metadata = { title: 'Download Volisle', alternates: alternates('en', '/download/') };
export default function Page() { return <DownloadPage locale="en"/>; }
