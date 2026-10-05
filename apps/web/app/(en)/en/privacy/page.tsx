import type { Metadata } from 'next';
import { alternates } from '@/lib/i18n';
import { ArticlePage } from '@/components/ArticlePage';
import { release } from '@/lib/release';
export const metadata: Metadata = { title: 'Privacy', alternates: alternates('en', '/privacy/') };
export default function Page() { return <ArticlePage locale="en" title="Your files stay on your drive." lead="September 25, 2026. Volisle has no accounts, analytics, or telemetry, and its core features run entirely on your Mac.">
<h2>What the app reads</h2><p>To show and manage disks, Volisle reads volume names, file systems, mount locations, capacity, and device identifiers from macOS. They’re used only on your Mac and never uploaded. Volisle doesn’t scan file contents or collect administrator passwords.</p>
<h2>What it stores on your Mac</h2><p>Preferences such as appearance, automatic write access, and updates; the disk connection identifiers and operation state needed to safely recover background operations; and recovery records while writing (kept in the Volisle file system extension’s own container and deleted automatically after a normal eject). None of this leaves your Mac.</p>
<h2>Network</h2><p>Volisle connects only to check for and download updates, from qisw.top/volisle/updates/. Requests contain no disk identifiers, volume names, file paths, or contents, and no system profile is sent. The server sees the usual IP address, time, and client information; the update folder keeps no access logs, only server error logs for troubleshooting.</p>
<h2>This website</h2><p>This site is static, with no analytics scripts, ads, forms, or third-party fonts.</p>
<h2>Diagnostics</h2><p>Diagnostics are created only when you export them, and are saved where you choose. They contain only the system version, component status, number of disks, and file system types.</p>
<h2>Operator</h2><p>{release.contact ? `Independent developer · ${release.contact}` : 'An independent developer.'}</p>
</ArticlePage>; }
