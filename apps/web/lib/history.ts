/** Retained public releases, newest first. The release script
 * (scripts/release/release.sh) moves the current release here when it publishes
 * the next one. Remove retired downloads here when pruning old releases.
 * Hashes must match the uploaded files. */
export type PastRelease = {
  version: string; build: number; date: string; dateEn: string;
  dmg: string; dmgSize: string; dmgSha256: string;
  source: string; sourceSize: string; sourceSha256: string;
};

export const history: PastRelease[] = [
  { version: '0.8.2', build: 69, date: '2026 年 10 月 7 日', dateEn: 'October 7, 2026',
    dmg: '/downloads/Volisle-0.8.2-arm64.dmg', dmgSize: '5.2 MB', dmgSha256: 'b96025ed3291881c41ccf53c3ac107e327e5abcdc4a7d7533bbdfe8c85492de7',
    source: '/downloads/Volisle-0.8.2-source.tar.gz', sourceSize: '19.8 MB', sourceSha256: '50558f654dc55018c80be764c0afb36bd62952b1dbac4fda4c0fc0080dc6c8cd' },
  { version: '0.8.0', build: 66, date: '2026 年 10 月 6 日', dateEn: 'October 6, 2026',
    dmg: '/downloads/Volisle-0.8.0-arm64.dmg', dmgSize: '4.9 MB', dmgSha256: 'ab71841e57ea007534252dd1b5aea886e3b44fd5577e0f7d5852d9aeaedd6692',
    source: '/downloads/Volisle-0.8.0-source.tar.gz', sourceSize: '19.7 MB', sourceSha256: '7dc1031e71be133d183e029053aa918591ce5de8fb787c942bb1b99484707edd' },
  { version: '0.7.0', build: 65, date: '2026 年 10 月 6 日', dateEn: 'October 6, 2026',
    dmg: '/downloads/Volisle-0.7.0-arm64.dmg', dmgSize: '4.3 MB', dmgSha256: 'd683e688bbf19c258d668d4b06ea2102d60c29c670dcf96d36aed91b3da28888',
    source: '/downloads/Volisle-0.7.0-source.tar.gz', sourceSize: '19.7 MB', sourceSha256: '74a3a7373f22a2a11ebf89e49901f230fc669493ee00eb0454c04d92dbfe3964' },
  { version: '0.6.1', build: 64, date: '2026 年 10 月 5 日', dateEn: 'October 5, 2026',
    dmg: '/downloads/Volisle-0.6.1-arm64.dmg', dmgSize: '4.2 MB', dmgSha256: 'e50a792891efd6262f6702cd703fb57296ab854d07a9f8ce5f154d8a1fa21999',
    source: '/downloads/Volisle-0.6.1-source.tar.gz', sourceSize: '19.6 MB', sourceSha256: '812a2b12408a107fc4c0053c2caad366a960d5777a4b2a6d3723a0b6e8889947' },
  { version: '0.6.0', build: 63, date: '2026 年 10 月 5 日', dateEn: 'October 5, 2026',
    dmg: '/downloads/Volisle-0.6.0-arm64.dmg', dmgSize: '4.2 MB', dmgSha256: '9504ff4ecc412b84b4c64c7f2f365da3d4be990d6ea45af583efb2d7172433a7',
    source: '/downloads/Volisle-0.6.0-source.tar.gz', sourceSize: '19.6 MB', sourceSha256: '4706afee8e2a18da63779941ec97bd60c37edc288a3e067d4f23c58d9fa97952' },
  { version: '0.5.8', build: 62, date: '2026 年 10 月 5 日', dateEn: 'October 5, 2026',
    dmg: '/downloads/Volisle-0.5.8-arm64.dmg', dmgSize: '4.2 MB', dmgSha256: 'f7de34c2996d2b63765f9e668149c0c9ffa217d0ae58f9e2409e90b4454b6e8d',
    source: '/downloads/Volisle-0.5.8-source.tar.gz', sourceSize: '19.6 MB', sourceSha256: '084024d6141f1b0880d25f332e42689214aa20770eb71ddecd1322b225ba6818' },
  { version: '0.5.7', build: 61, date: '2026 年 10 月 5 日', dateEn: 'October 5, 2026',
    dmg: '/downloads/Volisle-0.5.7-arm64.dmg', dmgSize: '4.2 MB', dmgSha256: 'b3ea6ac26ec61ae70ae364f8ec7c21d1660db4ee859f3fa3babe400ca6a0d24e',
    source: '/downloads/Volisle-0.5.7-source.tar.gz', sourceSize: '19.6 MB', sourceSha256: '3821be67345572a9b7b3f2f831c620cd9fc029c39ec9c7726189724e5764a2ec' },
  { version: '0.5.6', build: 60, date: '2026 年 10 月 5 日', dateEn: 'October 5, 2026',
    dmg: '/downloads/Volisle-0.5.6-arm64.dmg', dmgSize: '4.2 MB', dmgSha256: '6e5bca1551128a8de6451b150e1ceee5d1ae7cbba44bfa33ef2ce9bc5867b739',
    source: '/downloads/Volisle-0.5.6-source.tar.gz', sourceSize: '19.5 MB', sourceSha256: '888ecc14686d3aa2f62bcbfa910f8ba5edfb3b518c56533da365a26479d4f20f' },
  { version: '0.5.5', build: 59, date: '2026 年 10 月 4 日', dateEn: 'October 4, 2026',
    dmg: '/downloads/Volisle-0.5.5-arm64.dmg', dmgSize: '4.2 MB', dmgSha256: '807c9997188870e4f2685a5647e408b9c38de18aa84153f9d05bc02d1203f4ac',
    source: '/downloads/Volisle-0.5.5-source.tar.gz', sourceSize: '19.5 MB', sourceSha256: '7c93d9f8ef73b177559c698577484473c254c1b51df9b5f86e46d10688659a13' },
  { version: '0.5.4', build: 58, date: '2026 年 10 月 4 日', dateEn: 'October 4, 2026',
    dmg: '/downloads/Volisle-0.5.4-arm64.dmg', dmgSize: '4.1 MB', dmgSha256: 'b62f7ee2ac7a98c523d248a0fc1902b98db3b7227305a1be1386137ec90c5dc4',
    source: '/downloads/Volisle-0.5.4-source.tar.gz', sourceSize: '19.5 MB', sourceSha256: '9eedc13b01255dda37beb73f5e45dc892beb61bbd5ae68ebdd9167d334332370' },
  { version: '0.5.3', build: 57, date: '2026 年 10 月 3 日', dateEn: 'October 3, 2026',
    dmg: '/downloads/Volisle-0.5.3-arm64.dmg', dmgSize: '4.1 MB', dmgSha256: 'b1c72629d08ba76c052a918dc743ecd579f4329e8413a06cabed9d9e62e8be37',
    source: '/downloads/Volisle-0.5.3-source.tar.gz', sourceSize: '19.5 MB', sourceSha256: 'ab2ef2557b051a7b8d22f3d5b49efc126120efe624231b43ded1839c9c00829c' },
  { version: '0.5.2', build: 56, date: '2026 年 10 月 3 日', dateEn: 'October 3, 2026',
    dmg: '/downloads/Volisle-0.5.2-arm64.dmg', dmgSize: '4.1 MB', dmgSha256: 'e2c79236a2a18d9af9821b8c4061a0159591196cfd4f24b1cea71b1a7c3d0de5',
    source: '/downloads/Volisle-0.5.2-source.tar.gz', sourceSize: '19.5 MB', sourceSha256: 'ae93762d762b3852e514f6e475872ab9ccc79f3a0aaa98432a7eb949049cee18' },
  { version: '0.5.1', build: 55, date: '2026 年 10 月 3 日', dateEn: 'October 3, 2026',
    dmg: '/downloads/Volisle-0.5.1-arm64.dmg', dmgSize: '4.1 MB', dmgSha256: 'd159473598ad7ce96811d9260557652c2612e41499361622abc28f27b9752b58',
    source: '/downloads/Volisle-0.5.1-source.tar.gz', sourceSize: '19.5 MB', sourceSha256: '7aeb8b6dea9d758faa2e7d540b8692298542030ac6936af0d31b25ab34b4dd10' },
  { version: '0.5.0', build: 54, date: '2026 年 9 月 30 日', dateEn: 'September 30, 2026',
    dmg: '/downloads/Volisle-0.5.0-arm64.dmg', dmgSize: '4.0 MB', dmgSha256: 'd654ba74bc65ea32cf7cfce4e1a46e25251f263518956ba0d4b4eeb3544b21de',
    source: '/downloads/Volisle-0.5.0-source.tar.gz', sourceSize: '19.5 MB', sourceSha256: '98ad745366abd0943c4d6c8cba85a8dd3a3b86cf88ae1aa80a2953474b4a3c54' },
];
