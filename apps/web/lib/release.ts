/** The one place that says whether a public build exists. Flip `published`
 * only together with a notarized, verified package and its update entry. */
export const release = {
  version: '0.8.4',
  build: 71,
  date: '2026 年 10 月 8 日',
  /** English date for /en/ pages; update together with `date`. */
  dateEn: 'October 8, 2026',
  published: true,
  /** Paths below the site base; must match the uploaded files byte for byte. */
  dmg: '/downloads/Volisle-0.8.4-arm64.dmg',
  dmgSize: '6.2 MB',
  dmgSha256: 'ca8867273a0c28ab09745da74b7a6d7bc9f53b8c121c7c0952d94a2563df34a0',
  source: '/downloads/Volisle-0.8.4-source.tar.gz',
  sourceSize: '20.2 MB',
  sourceSha256: '52cb271af1568c1e82dc3125b24a2128aa2e53451265573c1901680efc88cede',
  minimumSystem: 'macOS 15.4',
  verifiedSystem: 'Apple 芯片 Mac · macOS 27.2',
  /** Publisher name and contact; must be confirmed by the owner before publishing. */
  publisher: '个人开发者' as string,
  contact: '' as string,
};
