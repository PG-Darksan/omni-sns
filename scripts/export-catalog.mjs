import * as esbuild from 'esbuild';
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const rootDir = path.resolve(__dirname, '..');

export async function exportCatalogFiles({ includeMobile = true } = {}) {
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
  delete require.cache[require.resolve(tempOut)];
  const mod = require(tempOut);
  const payload = {
    categories: mod.CATEGORIES,
    services: mod.SERVICE_CATALOG
  };
  const json = JSON.stringify(payload, null, 2);

  const targets = [path.join(rootDir, 'src-tauri', 'assets', 'catalog.json')];
  if (includeMobile) {
    targets.push(path.join(rootDir, 'mobile', 'assets', 'catalog.json'));
  }

  for (const targetPath of targets) {
    fs.mkdirSync(path.dirname(targetPath), { recursive: true });
    fs.writeFileSync(targetPath, json, 'utf-8');
  }

  fs.rmSync(tempOut, { force: true });
  console.log(
    `[export-catalog] Exported ${payload.categories.length} categories and ${payload.services.length} services to ${targets.length} target(s).`
  );
}

const isDirectRun =
  process.argv[1] && path.resolve(process.argv[1]) === path.resolve(__filename);

if (isDirectRun) {
  exportCatalogFiles({ includeMobile: true }).catch((err) => {
    console.error('[export-catalog] Failed:', err);
    process.exit(1);
  });
}
