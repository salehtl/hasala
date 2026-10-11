/**
 * Builds the web icons from the Paper board "Favicon & touch icon usage"
 * (page 13) and the brand files in src/assets/brand. Run with `bun run icons`
 * after the mark changes; the outputs are committed to public/.
 *
 *   favicon.svg            light tile, and the ink tile in dark browser chrome
 *   favicon.ico            hand-tuned 16 and 32 drawings + 48 from the SVG
 *   apple-touch-icon.png   180, downscaled hasala-icon-1024-light.png
 *   icon-192/512.png       web manifest, purpose "any"
 *   icon-maskable-512.png  mark scaled to 0.86 inside the safe zone
 *   mask-icon.svg          one colour, slot navy
 *   brand/hasala-wordmark.svg  the lockup with coordinates rounded (smaller)
 *   og-image.png           re-encoded smaller, same pixels
 */
import sharp from 'sharp';
import { readFile, writeFile, mkdir } from 'node:fs/promises';

const pub = new URL('../public/', import.meta.url);
const brand = new URL('../src/assets/brand/', import.meta.url);
const out = (p: string) => new URL(p, pub);

const COIN = '<linearGradient id="c" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#F9DC94"/><stop offset="1" stop-color="#EBB04A"/></linearGradient>';
const MARK = (plate: string) => `
  <rect x="212" y="576" width="600" height="112" rx="56" fill="${plate}"/>
  <rect x="244" y="600" width="536" height="64" rx="32" fill="#142659"/>
  <g clip-path="url(#k)">
    <circle cx="512" cy="538.2" r="184" fill="#C98A1E"/>
    <circle cx="512" cy="519.8" r="184" fill="url(#c)"/>
    <line x1="442.1" y1="486.7" x2="581.9" y2="486.7" stroke="#8A5A05" stroke-width="25.8" stroke-linecap="round"/>
    <line x1="442.1" y1="552.9" x2="581.9" y2="552.9" stroke="#8A5A05" stroke-width="25.8" stroke-linecap="round"/>
  </g>`;

// 48 px and up. The plate is dropped (as on the board) so the slot reads at tab size.
const faviconSvg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
<defs><linearGradient id="t" x1="0" y1="0" x2="0.4" y2="1"><stop offset="0" stop-color="#5479FF"/><stop offset="1" stop-color="#2B4AD2"/></linearGradient><linearGradient id="d" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#2C2C30"/><stop offset="1" stop-color="#121214"/></linearGradient>${COIN}<clipPath id="k"><rect x="-200" y="-200" width="1424" height="832"/></clipPath></defs>
<style>.ink{display:none}@media (prefers-color-scheme:dark){.ink{display:inline}.blue{display:none}}</style>
<rect class="blue" width="1024" height="1024" rx="230" fill="url(#t)"/>
<rect class="ink" width="1024" height="1024" rx="230" fill="url(#d)"/>
<g transform="translate(512 512) scale(1.1) translate(-512 -512)">${MARK('none').replace('<rect x="212" y="576" width="600" height="112" rx="56" fill="none"/>', '')}</g>
</svg>`;

// Hand-tuned 32 and 16 drawings from the board.
const TILE32 = '<linearGradient id="t" x1="0" y1="0" x2="0.4" y2="1"><stop offset="0" stop-color="#5479FF"/><stop offset="1" stop-color="#2B4AD2"/></linearGradient>';
const svg32 = `<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 32 32"><defs>${TILE32}<clipPath id="k"><rect width="32" height="20.5"/></clipPath></defs><rect width="32" height="32" rx="7.5" fill="url(#t)"/><rect x="5" y="18.5" width="22" height="4.5" rx="2.25" fill="#142659"/><g clip-path="url(#k)"><circle cx="16" cy="16.6" r="7.6" fill="#F1C66E"/><path d="M13 14.6h6M13 17.4h6" stroke="#8A5A05" stroke-width="1.3" stroke-linecap="round"/></g></svg>`;
const svg16 = `<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 32 32"><defs>${TILE32}<clipPath id="k"><rect width="32" height="20.5"/></clipPath></defs><rect width="32" height="32" rx="7.5" fill="url(#t)"/><rect x="4" y="18" width="24" height="5.5" rx="2.75" fill="#142659"/><g clip-path="url(#k)"><circle cx="16" cy="16" r="8.5" fill="#F1C66E"/></g></svg>`;

const maskableSvg = `<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 1024 1024"><defs><linearGradient id="t" x1="0" y1="0" x2="0.4" y2="1"><stop offset="0" stop-color="#5479FF"/><stop offset="1" stop-color="#2B4AD2"/></linearGradient>${COIN}<clipPath id="k"><rect x="-200" y="-200" width="1424" height="832"/></clipPath></defs><rect width="1024" height="1024" fill="url(#t)"/><g transform="translate(512 512) scale(0.86) translate(-512 -512)">${MARK('#FFFFFF24')}</g></svg>`;

const maskIcon = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="204 328 616 368"><defs><clipPath id="k"><rect x="-200" y="-200" width="1424" height="784"/></clipPath><mask id="m"><rect x="204" y="328" width="616" height="368" fill="#fff"/><line x1="442.1" y1="486.7" x2="581.9" y2="486.7" stroke="#000" stroke-width="25.8" stroke-linecap="round"/><line x1="442.1" y1="552.9" x2="581.9" y2="552.9" stroke="#000" stroke-width="25.8" stroke-linecap="round"/></mask></defs><g fill="#142659" mask="url(#m)"><rect x="244" y="600" width="536" height="64" rx="32"/><circle cx="512" cy="519.8" r="184" clip-path="url(#k)"/></g></svg>`;

const png = (svg: string, size: number) => sharp(Buffer.from(svg), { density: 72 * (size / 32) * 4 }).resize(size, size).png().toBuffer();

/** An ICO file whose entries are PNGs (supported everywhere that matters). */
function ico(images: { size: number; data: Buffer }[]): Buffer {
  const header = Buffer.alloc(6);
  header.writeUInt16LE(0, 0);
  header.writeUInt16LE(1, 2);
  header.writeUInt16LE(images.length, 4);
  const dir = Buffer.alloc(16 * images.length);
  let offset = 6 + dir.length;
  images.forEach((img, i) => {
    const o = i * 16;
    dir.writeUInt8(img.size >= 256 ? 0 : img.size, o);
    dir.writeUInt8(img.size >= 256 ? 0 : img.size, o + 1);
    dir.writeUInt8(0, o + 2);
    dir.writeUInt8(0, o + 3);
    dir.writeUInt16LE(1, o + 4);
    dir.writeUInt16LE(32, o + 6);
    dir.writeUInt32LE(img.data.length, o + 8);
    dir.writeUInt32LE(offset, o + 12);
    offset += img.data.length;
  });
  return Buffer.concat([header, dir, ...images.map((i) => i.data)]);
}

/** Round every number in path data and attributes to two decimals. */
const roundSvg = (s: string) => s.replace(/-?\d+\.\d{3,}/g, (n) => String(Math.round(Number(n) * 100) / 100));

await mkdir(out('brand/'), { recursive: true });

const lightPng = await readFile(new URL('hasala-icon-1024-light.png', brand));
await writeFile(out('favicon.svg'), faviconSvg);
await writeFile(out('mask-icon.svg'), maskIcon);
await writeFile(out('apple-touch-icon.png'), await sharp(lightPng).resize(180, 180).png({ compressionLevel: 9 }).toBuffer());
await writeFile(out('icon-192.png'), await sharp(lightPng).resize(192, 192).png({ compressionLevel: 9 }).toBuffer());
await writeFile(out('icon-512.png'), await sharp(lightPng).resize(512, 512).png({ compressionLevel: 9 }).toBuffer());
await writeFile(out('icon-maskable-512.png'), await sharp(Buffer.from(maskableSvg)).resize(512, 512).png({ compressionLevel: 9 }).toBuffer());
await writeFile(
  out('favicon.ico'),
  ico([
    { size: 16, data: await png(svg16, 16) },
    { size: 32, data: await png(svg32, 32) },
    { size: 48, data: await sharp(Buffer.from(faviconSvg.replace(/<style>.*?<\/style>/s, '').replace('<rect class="ink"', '<rect style="display:none"')), { density: 300 }).resize(48, 48).png().toBuffer() },
  ]),
);

const wordmark = await readFile(new URL('hasala-wordmark.svg', brand), 'utf8');
await writeFile(out('brand/hasala-wordmark.svg'), roundSvg(wordmark.replace(/<!--[\s\S]*?-->\s*/g, '')));

const og = new URL('og-image.png', pub);
const ogBuf = await readFile(og);
const smaller = await sharp(ogBuf).png({ palette: true, quality: 92, effort: 10, compressionLevel: 9 }).toBuffer();
if (smaller.length < ogBuf.length) await writeFile(og, smaller);

console.log('icons written');
