#!/usr/bin/env node
/*
 * render-sweep.cjs — driver for bin/render-sweep.sh (Campaign 3 C3.1).
 *
 * Invoked ONLY by the wrapper after it has verified node + a resolvable
 * local playwright (NODE_PATH may point at a sibling project's
 * node_modules). Renders every route at every width in light and dark
 * emulation (reduced-motion emulated throughout for stable captures),
 * saves full-page PNGs, and probes the three mechanically observable
 * defect classes:
 *
 *   overflow  — documentElement scrollWidth > clientWidth
 *   ground    — computed background-color of html AND body both
 *               transparent = the ELP_035 unpainted canvas; plus a literal
 *               bottom-center pixel decoded from the narrowest full-page
 *               capture (one sample per route × scheme)
 *   fracture  — a word (≥4 chars, no hyphen/soft-hyphen) inside a rendered
 *               h1–h6 whose Range spans more than one line box: a
 *               word-boundary wrap never splits a word across rects, so
 *               multiple rects = the ELP_034 mid-word fracture
 *
 * Composition judgment (rank, axis, species, optical centering) is NOT
 * probed — that is /render-audit's model-judged checklist. Exit 0 = probes
 * clean; 1 = at least one probe failure; 2 = driver error.
 */
'use strict';

const fs = require('fs');
const path = require('path');
const http = require('http');
const zlib = require('zlib');

function parseArgs(argv) {
  const a = {};
  for (let i = 2; i < argv.length; i += 2) a[argv[i].replace(/^--/, '')] = argv[i + 1];
  return a;
}

function loadConfig(file) {
  if (!file) return {};
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

// --- tiny static file server (for --serve-dist; no dependency) -------------
const MIME = {
  '.html': 'text/html', '.css': 'text/css', '.js': 'text/javascript',
  '.mjs': 'text/javascript', '.json': 'application/json', '.svg': 'image/svg+xml',
  '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg',
  '.webp': 'image/webp', '.avif': 'image/avif', '.ico': 'image/x-icon',
  '.woff2': 'font/woff2', '.woff': 'font/woff', '.txt': 'text/plain',
};
function serveDir(root) {
  return new Promise((resolve) => {
    const abs = path.resolve(root);
    const server = http.createServer((req, res) => {
      let u = decodeURIComponent((req.url || '/').split('?')[0]);
      if (u.endsWith('/')) u += 'index.html';
      let fp = path.normalize(path.join(abs, u));
      if (!fp.startsWith(abs)) { res.statusCode = 403; res.end(); return; }
      fs.readFile(fp, (err, data) => {
        if (err) {
          // Astro-style clean URLs: /route -> /route/index.html
          fs.readFile(path.join(fp, 'index.html'), (err2, data2) => {
            if (err2) { res.statusCode = 404; res.end('not found'); return; }
            res.setHeader('content-type', 'text/html');
            res.end(data2);
          });
          return;
        }
        res.setHeader('content-type', MIME[path.extname(fp)] || 'application/octet-stream');
        res.end(data);
      });
    });
    server.listen(0, '127.0.0.1', () => resolve({ server, port: server.address().port }));
  });
}

// --- minimal PNG bottom-pixel decode (zlib is built in) ---------------------
function pngBottomCenterPixel(buf) {
  try {
    if (buf.readUInt32BE(0) !== 0x89504e47) return null;
    let off = 8, width = 0, height = 0, bitDepth = 0, colorType = 0, interlace = 0;
    const idat = [];
    while (off < buf.length) {
      const len = buf.readUInt32BE(off);
      const type = buf.toString('ascii', off + 4, off + 8);
      const data = buf.subarray(off + 8, off + 8 + len);
      if (type === 'IHDR') {
        width = data.readUInt32BE(0); height = data.readUInt32BE(4);
        bitDepth = data[8]; colorType = data[9]; interlace = data[12];
      } else if (type === 'IDAT') idat.push(data);
      else if (type === 'IEND') break;
      off += 12 + len;
    }
    if (bitDepth !== 8 || interlace !== 0 || (colorType !== 6 && colorType !== 2)) return null;
    const ch = colorType === 6 ? 4 : 3;
    const raw = zlib.inflateSync(Buffer.concat(idat));
    const stride = width * ch;
    const recon = Buffer.alloc(height * stride);
    const paeth = (a, b, c) => {
      const p = a + b - c, pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c);
      return pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
    };
    for (let y = 0; y < height; y++) {
      const f = raw[y * (stride + 1)];
      const line = raw.subarray(y * (stride + 1) + 1, (y + 1) * (stride + 1));
      for (let x = 0; x < stride; x++) {
        const left = x >= ch ? recon[y * stride + x - ch] : 0;
        const up = y > 0 ? recon[(y - 1) * stride + x] : 0;
        const ul = y > 0 && x >= ch ? recon[(y - 1) * stride + x - ch] : 0;
        let v = line[x];
        if (f === 1) v = (v + left) & 0xff;
        else if (f === 2) v = (v + up) & 0xff;
        else if (f === 3) v = (v + ((left + up) >> 1)) & 0xff;
        else if (f === 4) v = (v + paeth(left, up, ul)) & 0xff;
        recon[y * stride + x] = v;
      }
    }
    const px = (height - 2) * stride + Math.floor(width / 2) * ch;
    const hex = (n) => recon[px + n].toString(16).padStart(2, '0');
    return `#${hex(0)}${hex(1)}${hex(2)}`;
  } catch {
    return null;
  }
}

// --- in-page probes ---------------------------------------------------------
const PROBE_FN = `() => {
  const de = document.documentElement;
  const csBody = getComputedStyle(document.body);
  const csHtml = getComputedStyle(de);
  const transparent = (c) => c === 'rgba(0, 0, 0, 0)' || c === 'transparent';
  const fractures = [];
  for (const h of document.querySelectorAll('h1,h2,h3,h4,h5,h6')) {
    const walker = document.createTreeWalker(h, NodeFilter.SHOW_TEXT);
    let node;
    while ((node = walker.nextNode())) {
      const text = node.textContent || '';
      const re = /[^\\s\\u00AD\\u2010-\\u2014-]{4,}/g;
      let m;
      while ((m = re.exec(text))) {
        const r = document.createRange();
        r.setStart(node, m.index);
        r.setEnd(node, m.index + m[0].length);
        const rects = Array.from(r.getClientRects()).filter((x) => x.width > 0.5 && x.height > 0.5);
        const lines = new Set(rects.map((x) => Math.round(x.top)));
        if (lines.size > 1) {
          fractures.push({ heading: h.tagName.toLowerCase(), word: m[0].slice(0, 40) });
        }
      }
    }
  }
  return {
    scrollWidth: de.scrollWidth,
    clientWidth: de.clientWidth,
    scrollHeight: de.scrollHeight,
    bodyBg: csBody.backgroundColor,
    htmlBg: csHtml.backgroundColor,
    bodyImage: csBody.backgroundImage !== 'none',
    bodySize: csBody.backgroundSize,
    unpainted: transparent(csBody.backgroundColor) && transparent(csHtml.backgroundColor),
    colorScheme: csHtml.colorScheme,
    fractures,
  };
}`;

function slug(route) {
  const s = route.replace(/^\/+|\/+$/g, '').replace(/[^A-Za-z0-9_-]+/g, '-');
  return s === '' ? 'root' : s;
}

(async () => {
  const args = parseArgs(process.argv);
  const cfg = loadConfig(args.config || '');
  const base = args.base || cfg.base || '';
  const serveDist = args['serve-dist'] || cfg.serveDist || '';
  const routes = (args.routes && args.routes !== '/' ? args.routes : (cfg.routes || ['/']).join(','))
    .split(',').map((r) => r.trim()).filter(Boolean);
  const widths = (args.widths || (cfg.widths || []).join(',') || '320,360,390,414,640,768,834,1024,1280,1440')
    .split(',').map((w) => parseInt(w, 10)).filter((w) => w > 0);
  const out = args.out || cfg.out || 'tmp/render-sweep';
  fs.mkdirSync(out, { recursive: true });

  let server = null;
  let origin = base;
  if (!origin && serveDist) {
    const s = await serveDir(serveDist);
    server = s.server;
    origin = `http://127.0.0.1:${s.port}`;
  }
  if (!origin) { console.error('render-sweep.cjs: no --base and no --serve-dist'); process.exit(2); }
  origin = origin.replace(/\/+$/, '');

  const { chromium } = require('playwright');
  const browser = await chromium.launch();
  const rows = [];
  const findings = [];
  const SAMPLE_WIDTH = Math.min(...widths);

  try {
    for (const scheme of ['light', 'dark']) {
      const context = await browser.newContext({
        colorScheme: scheme,
        reducedMotion: 'reduce',
        viewport: { width: 1280, height: 900 },
        deviceScaleFactor: 1,
      });
      const page = await context.newPage();
      for (const route of routes) {
        const dir = path.join(out, slug(route));
        fs.mkdirSync(dir, { recursive: true });
        for (const width of widths) {
          await page.setViewportSize({ width, height: 900 });
          const row = { route, scheme, width, overflow: null, fractures: [], ground: null, pixel: null, error: null };
          try {
            await page.goto(origin + route, { waitUntil: 'networkidle', timeout: 20000 });
            const shot = path.join(dir, `${scheme}-${width}.png`);
            const buf = await page.screenshot({ fullPage: true, path: shot });
            const p = await page.evaluate(`(${PROBE_FN})()`);
            row.overflow = p.scrollWidth - p.clientWidth;
            row.fractures = p.fractures;
            row.ground = p;
            if (width === SAMPLE_WIDTH) row.pixel = pngBottomCenterPixel(buf);
          } catch (e) {
            row.error = String(e && e.message ? e.message.split('\n')[0] : e);
          }
          rows.push(row);
          if (row.error) findings.push({ kind: 'error', route, scheme, width, detail: row.error });
          else {
            if (row.overflow > 0) findings.push({ kind: 'overflow', route, scheme, width, detail: `+${row.overflow}px horizontal overflow` });
            if (row.fractures.length > 0) findings.push({ kind: 'fracture', route, scheme, width, detail: row.fractures.map((f) => `${f.heading}: "${f.word}"`).join('; ') });
            if (row.ground && row.ground.unpainted) findings.push({ kind: 'unpainted-ground', route, scheme, width, detail: `html/body background-color both transparent (ELP_035)${row.pixel ? `; bottom pixel ${row.pixel}` : ''}` });
          }
        }
      }
      await context.close();
    }
  } finally {
    await browser.close();
    if (server) server.close();
  }

  // TSV table
  console.log('route\tscheme\twidth\toverflow\tfracture\tground');
  for (const r of rows) {
    if (r.error) { console.log(`${r.route}\t${r.scheme}\t${r.width}\tERROR\tERROR\t${r.error}`); continue; }
    const ground = r.ground.unpainted
      ? `UNPAINTED${r.pixel ? ` px${r.pixel}` : ''}`
      : `painted ${r.ground.bodyBg !== 'rgba(0, 0, 0, 0)' ? r.ground.bodyBg : r.ground.htmlBg}${r.pixel ? ` px${r.pixel}` : ''}`;
    console.log([
      r.route, r.scheme, r.width,
      r.overflow > 0 ? `+${r.overflow}px` : 'ok',
      r.fractures.length > 0 ? `FRACTURE ${r.fractures[0].heading}:"${r.fractures[0].word}"` : 'ok',
      ground,
    ].join('\t'));
  }

  fs.writeFileSync(path.join(out, 'probes.json'), JSON.stringify({ origin, widths, routes, rows, findings }, null, 2));
  const bad = findings.filter((f) => f.kind !== 'error');
  const errs = findings.filter((f) => f.kind === 'error');
  console.log('---');
  console.log(`captures: ${rows.length} (${routes.length} route(s) × ${widths.length} width(s) × 2 schemes) → ${out}`);
  console.log(`probe failures: ${bad.length}${errs.length ? `, errors: ${errs.length}` : ''}`);
  process.exit(bad.length > 0 || errs.length > 0 ? 1 : 0);
})().catch((e) => {
  console.error('render-sweep.cjs:', e && e.stack ? e.stack.split('\n').slice(0, 3).join('\n') : e);
  process.exit(2);
});
