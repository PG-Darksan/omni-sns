import * as esbuild from 'esbuild';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { exportCatalogFiles } from './export-catalog.mjs';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const rootDir = path.resolve(__dirname, '..');
const distDir = path.join(rootDir, 'dist');

async function build() {
  fs.rmSync(distDir, { recursive: true, force: true });
  fs.mkdirSync(path.join(distDir, 'renderer'), { recursive: true });
  fs.mkdirSync(path.join(distDir, 'tests'), { recursive: true });

  // 1. Export shared catalog JSON for Tauri (embedded via include_str!)
  await exportCatalogFiles({ includeMobile: false });

  // 2. Renderer script bundle (Browser IIFE, minified for release size)
  await esbuild.build({
    entryPoints: [path.join(rootDir, 'src', 'renderer', 'renderer.ts')],
    outfile: path.join(distDir, 'renderer', 'renderer.js'),
    bundle: true,
    minify: true,
    platform: 'browser',
    format: 'iife',
    target: 'chrome120'
  });

  // 3. Unit tests bundle
  const testEntry = path.join(rootDir, 'tests', 'core.test.ts');
  if (fs.existsSync(testEntry)) {
    await esbuild.build({
      entryPoints: [testEntry],
      outfile: path.join(distDir, 'tests', 'core.test.js'),
      bundle: true,
      platform: 'node',
      format: 'cjs',
      target: 'node20',
      sourcemap: true
    });
  }

  // 4. Copy static renderer assets
  fs.copyFileSync(
    path.join(rootDir, 'src', 'renderer', 'index.html'),
    path.join(distDir, 'renderer', 'index.html')
  );
  fs.copyFileSync(
    path.join(rootDir, 'src', 'renderer', 'styles.css'),
    path.join(distDir, 'renderer', 'styles.css')
  );

  console.log('[build] OmniSNS frontend & catalog build completed successfully.');
}

build().catch((err) => {
  console.error('[build] Build failed:', err);
  process.exit(1);
});
