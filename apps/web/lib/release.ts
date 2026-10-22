/** The one place that says whether a public build exists. Flip `published`
 * only together with a notarized, verified package and its update entry. */
export const release = {
  version: '0.9.6',
  build: 78,
  date: '2026 年 10 月 21 日',
  /** English date for /en/ pages; update together with `date`. */
  dateEn: 'October 21, 2026',
  published: true,
  /** Paths below the site base; must match the uploaded files byte for byte. */
  dmg: '/downloads/Volisle-0.9.6-universal.dmg',
  dmgSize: '12.7 MB',
  dmgSha256: 'd6f6c340429c8367e96a75fab752562c61883a9c85dc8c88b640de9b0c571777',
  source: '/downloads/Volisle-0.9.6-source.tar.gz',
  sourceSize: '20.3 MB',
  sourceSha256: '5eea7f423543989ffda0507d07e95cd9d4f90ce0764c7204756bbc1dbf04564c',
  minimumSystem: 'macOS 15.4',
  verifiedSystem: 'Apple 芯片 Mac · macOS 27.2',
  /** Publisher name and contact; must be confirmed by the owner before publishing. */
  publisher: '个人开发者' as string,
  contact: '' as string,
};
