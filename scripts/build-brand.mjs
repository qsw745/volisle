// 将已选定的 A 方案矢量母版编译为官网与 macOS 资源。不会处理或覆盖原始设计板。
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { resolve, join } from 'node:path';
import { execFileSync } from 'node:child_process';

const root = fileURLToPath(new URL('../', import.meta.url));
const webRequire = createRequire(join(root, 'apps/web/package.json'));
const sharp = createRequire(webRequire.resolve('next/package.json'))('sharp');
const geometry = JSON.parse(await readFile(join(root, 'assets/brand/geometry.json'), 'utf8'));
const paths = geometry.paths.map(d => `<path d="${d}"/>`).join('');
const mark = color => `<svg xmlns="http://www.w3.org/2000/svg" viewBox="${geometry.viewBox}" fill="${color}">${paths}</svg>`;
const appIcon = `<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<defs><linearGradient id="tile" x1="0" y1="0" x2=".85" y2="1"><stop stop-color="#FFFFFF"/><stop offset="1" stop-color="#E9EEF5"/></linearGradient><linearGradient id="sea" x1="0" y1="0" x2=".7" y2="1"><stop stop-color="#2279F0"/><stop offset="1" stop-color="#115CCC"/></linearGradient></defs>
<rect x="68" y="82" width="888" height="888" rx="204" fill="#172D4F" opacity=".08"/>
<rect x="64" y="60" width="896" height="896" rx="204" fill="url(#tile)" stroke="#DCE3ED" stroke-width="2"/>
<rect x="70" y="66" width="884" height="884" rx="200" fill="none" stroke="#FFF" stroke-width="4"/>
<g transform="translate(136 278)" fill="url(#sea)">${paths}</g></svg>`;
async function save(path, content) {
  const file = resolve(root, path);
  await mkdir(resolve(file, '..'), { recursive: true });
  await writeFile(file, content);
}
for (const [name, color] of [['mark', geometry.blue], ['mark-mono', '#202322'], ['mark-white', '#FFFFFF']]) {
  await save(`assets/brand/${name}.svg`, mark(color));
  await save(`assets/brand/${name}.png`, await sharp(Buffer.from(mark(color))).resize(1520, 920).png().toBuffer());
}
await save('assets/brand/app-icon.svg', appIcon);
await save('assets/brand/app-icon-1024.png', await sharp(Buffer.from(appIcon)).png().toBuffer());
await save('apps/web/app/icon.svg', appIcon);
await save('apps/web/app/apple-icon.png', await sharp(Buffer.from(appIcon)).resize(180, 180).png().toBuffer());
await save('apps/web/public/brand/mark.svg', mark(geometry.blue));
await save('apps/web/public/brand/app-icon.svg', appIcon);
await save('apps/web/components/BrandMark.tsx', `// 由 scripts/build-brand.mjs 从 assets/brand/geometry.json 生成。\nexport function BrandMark({ width = 32 }: { width?: number }) {\n  return <svg width={width} height={width * 460 / 760} viewBox="${geometry.viewBox}" fill="currentColor" aria-hidden="true" focusable="false">${geometry.paths.map(d => `<path d="${d}"/>`).join('')}</svg>;\n}\n`);
const resources = 'apps/macos/Sources/Volisle/Resources';
await save(`${resources}/BrandMark.png`, await sharp(Buffer.from(mark(geometry.blue))).resize(304, 184).png().toBuffer());
// 菜单栏固定 28 × 17 pt；两种像素密度由同一矢量轮廓生成。
for (const scale of [1, 2]) {
  await save(`${resources}/MenuBarTemplate${scale === 2 ? '@2x' : ''}.png`, await sharp(Buffer.from(mark('#000000'))).resize(28 * scale, 17 * scale).png().toBuffer());
}
const iconset = 'assets/brand/Volisle.iconset';
for (const size of [16, 32, 128, 256, 512]) {
  for (const scale of [1, 2]) {
    await save(`${iconset}/icon_${size}x${size}${scale === 2 ? '@2x' : ''}.png`, await sharp(Buffer.from(appIcon)).resize(size * scale).png().toBuffer());
  }
}
if (process.platform === 'darwin') {
  execFileSync('/usr/bin/iconutil', ['-c', 'icns', join(root, iconset), '-o', join(root, 'assets/brand/Volisle.icns')]);
}
const sizes = [16, 24, 32, 64];
const samples = sizes.map((size, index) => {
  const x = 48 + index * 140;
  return `<text x="${x}" y="42" font-family="sans-serif" font-size="13" fill="#66706B">${size} px</text><svg x="${x}" y="65" width="${size}" height="${size * 460 / 760}" viewBox="${geometry.viewBox}" fill="${geometry.blue}">${paths}</svg><svg x="${x}" y="143" width="${size}" height="${size}" viewBox="0 0 1024 1024">${appIcon.replace(/^<svg[^>]*>/, '').replace(/<\/svg>$/, '')}</svg><svg x="${x}" y="252" width="${size}" height="${size * 460 / 760}" viewBox="${geometry.viewBox}" fill="#FFFFFF">${paths}</svg>`;
}).join('');
const sheet = `<svg xmlns="http://www.w3.org/2000/svg" width="640" height="320"><rect width="640" height="320" fill="#F7F7F4"/><rect y="225" width="640" height="95" fill="#202322"/>${samples}</svg>`;
await save('assets/brand/size-check.svg', sheet);
await save('assets/brand/size-check.png', await sharp(Buffer.from(sheet)).png().toBuffer());
console.log('品牌资源已生成：assets/brand、官网资源和 macOS 资源。');
