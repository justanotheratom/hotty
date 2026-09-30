// Renders scene.html frame by frame in headless Chrome and encodes it with ffmpeg.
//
//   node render.mjs video  out.mp4            1080p H.264, 30 fps
//   node render.mjs gif    out.gif            960 px wide, 12 fps, for the README
//   node render.mjs stills out-dir 3 12.5 40  PNGs at those times, for checking frames
//
// Needs ffmpeg and playwright-core (set PLAYWRIGHT_CORE to its path if it isn't installed
// here). Uses the installed Google Chrome.
import { spawn } from 'node:child_process';
import { mkdirSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';

const { chromium } = await import(process.env.PLAYWRIGHT_CORE ?? 'playwright-core');
const [mode, out, ...times] = process.argv.slice(2);
const here = path.dirname(fileURLToPath(import.meta.url));
const FPS = mode === 'gif' ? 12 : 30;
const SCALE = mode === 'gif' ? 0.75 : 1.5;

const browser = await chromium.launch({ channel: 'chrome' });
const page = await browser.newPage({ viewport: { width: 1280, height: 720 }, deviceScaleFactor: SCALE });
await page.goto(pathToFileURL(path.join(here, 'scene.html')).href + '?render');
await page.evaluate(() => document.fonts.ready);
const duration = await page.evaluate(() => window.DURATION);
const seek = t => page.evaluate(t => window.seek(t), t);
const shot = () => page.screenshot({ type: 'png' });

if (mode === 'stills') {
  mkdirSync(out, { recursive: true });
  const want = times.map(Number).sort((a, b) => a - b);
  let t = 0;
  for (const w of want) {
    for (; t < w; t += 1 / 30) await seek(t);   // captions fade based on the previous frames
    await seek(w);
    await page.screenshot({ path: path.join(out, `t${w.toFixed(1).padStart(5, '0')}.png`) });
  }
} else {
  const args = mode === 'gif'
    ? ['-y', '-f', 'image2pipe', '-framerate', String(FPS), '-i', '-',
       '-vf', 'split[a][b];[a]palettegen=max_colors=256:stats_mode=full[p];[b][p]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle',
       '-loop', '0', out]
    : ['-y', '-f', 'image2pipe', '-framerate', String(FPS), '-i', '-',
       '-c:v', 'libx264', '-preset', 'slow', '-crf', '20', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', out];
  const ff = spawn('ffmpeg', args, { stdio: ['pipe', 'ignore', 'inherit'] });
  const frames = Math.round(duration * FPS);
  for (let i = 0; i < frames; i++) {
    await seek(i / FPS);
    const buf = await shot();
    if (!ff.stdin.write(buf)) await new Promise(r => ff.stdin.once('drain', r));
    if (i % (FPS * 10) === 0) process.stderr.write(`frame ${i}/${frames}\n`);
  }
  ff.stdin.end();
  await new Promise((res, rej) => ff.on('close', c => (c ? rej(new Error(`ffmpeg exited ${c}`)) : res())));
}
await browser.close();
