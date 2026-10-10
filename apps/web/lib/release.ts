/** The one place that says whether a public build exists. Flip `published`
 * only together with a notarized, verified package and its update entry. */
export const release = {
  version: '0.9.1',
  build: 73,
  date: '2026 年 10 月 9 日',
  /** English date for /en/ pages; update together with `date`. */
  dateEn: 'October 9, 2026',
  published: true,
  /** Paths below the site base; must match the uploaded files byte for byte. */
  dmg: '/downloads/Volisle-0.9.1-universal.dmg',
  dmgSize: '11.9 MB',
  dmgSha256: '2b0e41012b2357f175a4cc5aa66b20123adb33eafa8ad5ece5faf641e9c36db1',
  source: '/downloads/Volisle-0.9.1-source.tar.gz',
  sourceSize: '20.2 MB',
  sourceSha256: '37668796108c9e83a707327eb88afb6e5e469526955d6637ab922a460efaef67',
  minimumSystem: 'macOS 15.4',
  verifiedSystem: 'Apple 芯片 Mac · macOS 27.2',
  /** Publisher name and contact; must be confirmed by the owner before publishing. */
  publisher: '个人开发者' as string,
  contact: '' as string,
};
