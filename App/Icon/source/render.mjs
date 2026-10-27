import { createRequire } from 'node:module';
import { readFile, writeFile, copyFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const require = createRequire(import.meta.url);
// SHARP_MODULE may point to a shared installation; no dependency download is needed.
const sharp = require(process.env.SHARP_MODULE || 'sharp');
const root = path.dirname(fileURLToPath(import.meta.url));
const bundle = path.join(root, 'Todo.icon');
const manifest = JSON.parse(await readFile(path.join(bundle, 'icon.json'), 'utf8'));
const names = ['background', ...manifest.groups.flatMap(group =>
  group.layers.map(layer => path.parse(layer['image-name']).name))];
const sources = new Map();

for (const name of names) {
  const svg = await readFile(path.join(root, `${name}.svg`));
  sources.set(name, svg.toString());
  const output = path.join(root, `${name}.png`);
  await sharp(svg).resize(1024, 1024).toColourspace('srgb').png().toFile(output);
  if (name !== 'background') {
    await copyFile(output, path.join(bundle, 'Assets', `${name}.png`));
  }
  const { data, info } = await sharp(output).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  let minAlpha = 255;
  let maxAlpha = 0;
  for (let i = 3; i < data.length; i += 4) {
    minAlpha = Math.min(minAlpha, data[i]);
    maxAlpha = Math.max(maxAlpha, data[i]);
  }
  if (info.width !== 1024 || info.height !== 1024 || maxAlpha !== 255 ||
      minAlpha !== (name === 'background' ? 255 : 0)) {
    throw new Error(`Unexpected dimensions or alpha: ${name}`);
  }
  console.log(`${name}.png: 1024 × 1024, alpha ${minAlpha}…${maxAlpha}`);
}

function appearanceFill(object, appearance) {
  return object['fill-specializations']?.find(item => item.appearance === appearance)?.value || object.fill;
}

function recolor(svg, fill) {
  let index = 0;
  return svg.replace(/stop-color="[^"]+"/g, () => {
    const components = fill['linear-gradient'][index++].split(':')[1].split(',').slice(0, 3);
    const color = components.map(value => Math.round(Number(value) * 255).toString(16).padStart(2, '0')).join('');
    return `stop-color="#${color}"`;
  });
}

for (const appearance of ['light', 'dark', 'tinted']) {
  const background = Buffer.from(recolor(sources.get('background'), appearanceFill(manifest, appearance)));
  const overlays = [];
  for (const group of manifest.groups) {
    for (const layer of group.layers) {
      const name = path.parse(layer['image-name']).name;
      overlays.push({ input: await sharp(Buffer.from(recolor(sources.get(name), appearanceFill(layer, appearance)))).png().toBuffer() });
    }
  }
  await sharp(background).composite(overlays).png().toFile(path.join(root, `preview-${appearance}.png`));
}

await writeFile(path.join(root, 'render-info.json'), JSON.stringify({
  renderer: 'Node.js / Sharp (SVG via librsvg, composition via libvips)',
  versions: { node: process.versions.node, sharp: sharp.versions.sharp, vips: sharp.versions.vips, rsvg: sharp.versions.rsvg },
  width: 1024,
  height: 1024,
  verified: ['PNG dimensions', 'background fully opaque', 'foreground transparent and opaque pixels', 'bundle assets copied from layer renders'],
  limitations: ['Static previews only; no Apple material, enclosure, lighting or system tint simulation', 'Icon Composer and Xcode import not verified']
}, null, 2) + '\n');
