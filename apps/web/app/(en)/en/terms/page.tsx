import type { Metadata } from 'next';
import { alternates } from '@/lib/i18n';
import { ArticlePage } from '@/components/ArticlePage';
export const metadata: Metadata = { title: 'License and Terms', alternates: alternates('en', '/terms/') };
export default function Page() { return <ArticlePage locale="en" title="Free, open source, and upfront." lead="September 25, 2026.">
<h2>License</h2><p>Volisle’s source code is released under the GNU GPL v2. The NTFS engine is based on NTFS-3G (GPL-2.0-or-later), and automatic updates use Sparkle (MIT License). Every installer comes with the complete corresponding source code, change records, and build scripts, and third-party license notices ship with the app.</p>
<h2>No warranty</h2><p>As set out in the GPL v2, this software is provided “as is”, without warranty of any kind, express or implied. Volisle keeps disks read-only when a check fails and recovers automatically after interruptions, but no software replaces a backup. Keep separate backups of important data.</p>
<h2>What’s not included</h2><p>Volisle doesn’t repair or repartition disks, recover data, or sync to the cloud. “Erase Disk” deletes all data on the chosen disk or partition and can’t be undone.</p>
<h2>Names and logos</h2><p>The names “盘屿” and “Volisle” and their logos are not licensed as trademarks under the source code license.</p>
</ArticlePage>; }
