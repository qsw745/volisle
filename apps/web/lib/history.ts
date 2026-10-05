/** Earlier public releases, newest first. Every file stays on the site; the
 * release script (scripts/release/release.sh) moves the current release here
 * when it publishes the next one. Hashes must match the uploaded files. */
export type PastRelease = {
  version: string; build: number; date: string; dateEn: string;
  dmg: string; dmgSize: string; dmgSha256: string;
  source: string; sourceSize: string; sourceSha256: string;
};

export const history: PastRelease[] = [
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
  { version: '0.4.0', build: 53, date: '2026 年 9 月 29 日', dateEn: 'September 29, 2026',
    dmg: '/downloads/Volisle-0.4.0-arm64.dmg', dmgSize: '3.8 MB', dmgSha256: '092d8eb22ed1e06138b42c3d961e82510f786e990ef0be653eb6930cf6d6c0ba',
    source: '/downloads/Volisle-0.4.0-source.tar.gz', sourceSize: '19.5 MB', sourceSha256: '95408375449245032b5936ab724033de9530532e49f28e3b4b0e953e2c3191b2' },
  { version: '0.3.3', build: 19, date: '2026 年 9 月 28 日', dateEn: 'September 28, 2026',
    dmg: '/downloads/Volisle-0.3.3-arm64.dmg', dmgSize: '3.4 MB', dmgSha256: '970749bb139eae6b95e6ffcfbe7d2e3ebb95a06b0cf45db5845a17db6136c6f2',
    source: '/downloads/Volisle-0.3.3-source.tar.gz', sourceSize: '19.4 MB', sourceSha256: '30432f10a943d361a3f1700884cd75e74797ea9723193464259b732ad8d475f8' },
  { version: '0.3.2', build: 18, date: '2026 年 9 月 27 日', dateEn: 'September 27, 2026',
    dmg: '/downloads/Volisle-0.3.2-arm64.dmg', dmgSize: '3.4 MB', dmgSha256: 'a992da36faf60e1f8d53500cb9311f5e8a6359b8b42da9e4173573bb3bc2a894',
    source: '/downloads/Volisle-0.3.2-source.tar.gz', sourceSize: '19.4 MB', sourceSha256: '84f55b601a702a429f624754ad7700f2ef6c102b4d0ec3baf0790c50ea4e4578' },
  { version: '0.3.1', build: 17, date: '2026 年 9 月 27 日', dateEn: 'September 27, 2026',
    dmg: '/downloads/Volisle-0.3.1-arm64.dmg', dmgSize: '3.4 MB', dmgSha256: '2e30f43b6878ed0b855f9f8da5747c19a8988ef7220c636edc776f628db51392',
    source: '/downloads/Volisle-0.3.1-source.tar.gz', sourceSize: '19.4 MB', sourceSha256: '28a3c72cb4ac848bd6318773effa9145f08f5600403ee1f2364cfeb03403734d' },
  { version: '0.3.0', build: 14, date: '2026 年 9 月 26 日', dateEn: 'September 26, 2026',
    dmg: '/downloads/Volisle-0.3.0-arm64.dmg', dmgSize: '3.4 MB', dmgSha256: 'fae7f2068e5125a3eba1d6613b9381254bf384d90a105aad763f61c0dcb4f980',
    source: '/downloads/Volisle-0.3.0-source.tar.gz', sourceSize: '19.3 MB', sourceSha256: 'd5cd0a0963d1514d6234b5f8d5cb659b8f96da986fb923f35140a826c5b40224' },
];
