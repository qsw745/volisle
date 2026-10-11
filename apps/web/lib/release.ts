/** The one place that says whether a public build exists. Flip `published`
 * only together with a notarized, verified package and its update entry. */
export const release = {
  version: '0.9.2',
  build: 74,
  date: '2026 年 10 月 10 日',
  /** English date for /en/ pages; update together with `date`. */
  dateEn: 'October 10, 2026',
  published: true,
  /** Paths below the site base; must match the uploaded files byte for byte. */
  dmg: '/downloads/Volisle-0.9.2-universal.dmg',
  dmgSize: '12.4 MB',
  dmgSha256: '42f022487a962cee2d831192c09818904f54904c9d459d045113ea600eb5cb13',
  source: '/downloads/Volisle-0.9.2-source.tar.gz',
  sourceSize: '20.2 MB',
  sourceSha256: 'c94ac8b839731b3eb70c9306109cf76620be6fafc905db4a0e65a247368bb8b3',
  minimumSystem: 'macOS 15.4',
  verifiedSystem: 'Apple 芯片 Mac · macOS 27.2',
  /** Publisher name and contact; must be confirmed by the owner before publishing. */
  publisher: '个人开发者' as string,
  contact: '' as string,
};
