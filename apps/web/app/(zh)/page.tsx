import type { Metadata } from 'next';
import { HomePage } from '@/components/HomePage';
import { alternates } from '@/lib/i18n';
export const metadata: Metadata = { alternates: alternates('zh', '/') };
export default function Home() { return <HomePage locale="zh"/>; }
