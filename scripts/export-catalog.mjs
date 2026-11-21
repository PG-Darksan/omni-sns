import * as esbuild from 'esbuild';
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const rootDir = path.resolve(__dirname, '..');

async function exportCatalog() {
  const tempOut = path.join(rootDir, 'dist', '_catalog_export.cjs');
  fs.mkdirSync(path.dirname(tempOut), { recursive: true });

  await esbuild.build({
    entryPoints: [path.join(rootDir, 'src', 'shared', 'catalog.ts')],
    outfile: tempOut,
    bundle: true,
    platform: 'node',
    format: 'cjs',
    target: 'node20'
  });

  const require = createRequire(import.meta.url);
  const mod = require(tempOut);
  const payload = {
    categories: mod.CATEGORIES,
    services: mod.SERVICE_CATALOG
  };

  const targetPath = path.join(rootDir, 'mobile', 'assets', 'catalog.json');
  fs.mkdirSync(path.dirname(targetPath), { recursive: true });
  fs.writeFileSync(targetPath, JSON.stringify(payload, null, 2), 'utf-8');
  fs.rmSync(tempOut, { force: true });

  console.log(
    `[export-catalog] Exported ${payload.categories.length} categories and ${payload.services.length} services to mobile/assets/catalog.json`
  );
}

exportCatalog().catch((err) => {
  console.error('[export-catalog] Failed:', err);
  process.exit(1);
});
