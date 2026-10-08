/** The one place that says whether a public build exists. Flip `published`
 * only together with a notarized, verified package and its update entry. */
export const release = {
  version: '0.8.2',
  build: 69,
  date: '2026 年 10 月 7 日',
  /** English date for /en/ pages; update together with `date`. */
  dateEn: 'October 7, 2026',
  published: true,
  /** Paths below the site base; must match the uploaded files byte for byte. */
  dmg: '/downloads/Volisle-0.8.2-arm64.dmg',
  dmgSize: '5.2 MB',
  dmgSha256: 'b96025ed3291881c41ccf53c3ac107e327e5abcdc4a7d7533bbdfe8c85492de7',
  source: '/downloads/Volisle-0.8.2-source.tar.gz',
  sourceSize: '19.8 MB',
  sourceSha256: '50558f654dc55018c80be764c0afb36bd62952b1dbac4fda4c0fc0080dc6c8cd',
  minimumSystem: 'macOS 15.4',
  verifiedSystem: 'Apple 芯片 Mac · macOS 27.2',
  /** Publisher name and contact; must be confirmed by the owner before publishing. */
  publisher: '个人开发者' as string,
  contact: '' as string,
};
