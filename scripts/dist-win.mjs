import { execSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const rootDir = path.resolve(__dirname, '..');

const pkg = JSON.parse(fs.readFileSync(path.join(rootDir, 'package.json'), 'utf-8'));
const version = pkg.version || '1.0.0';

function run(command) {
  console.log(`[dist:win] Running: ${command}`);
  execSync(command, {
    cwd: rootDir,
    stdio: 'inherit'
  });
}

function formatMB(bytes) {
  return `${(bytes / (1024 * 1024)).toFixed(2)} MB`;
}

function main() {
  // Build Tauri release binary + NSIS installer (beforeBuildCommand runs `npm run build`)
  run('npx tauri build --bundles nsis');

  const releaseDir = path.join(rootDir, 'release');
  fs.mkdirSync(releaseDir, { recursive: true });

  // Clean up old Electron build artifacts while preserving Android APK if present
  for (const stale of [
    'win-unpacked',
    '.icon-ico',
    'builder-debug.yml',
    'latest.yml',
    `OmniSNS-${version}-win-x64-setup.exe.blockmap`
  ]) {
    const stalePath = path.join(releaseDir, stale);
    if (fs.existsSync(stalePath)) {
      fs.rmSync(stalePath, { recursive: true, force: true });
    }
  }

  const targetReleaseDir = path.join(rootDir, 'src-tauri', 'target', 'release');
  const portableSrc = path.join(targetReleaseDir, 'omni-sns.exe');
  const portableDst = path.join(releaseDir, `OmniSNS-${version}-win-x64-portable.exe`);

  if (!fs.existsSync(portableSrc)) {
    throw new Error(`Expected release executable not found: ${portableSrc}`);
  }
  fs.copyFileSync(portableSrc, portableDst);

  const nsisDir = path.join(targetReleaseDir, 'bundle', 'nsis');
  const nsisCandidates = fs
    .readdirSync(nsisDir)
    .filter((name) => name.toLowerCase().endsWith('.exe'));
  const nsisExe =
    nsisCandidates.find((name) => name.includes(`_${version}_`) || name.includes(`-${version}-`)) ??
    nsisCandidates
      .map((name) => ({ name, mtime: fs.statSync(path.join(nsisDir, name)).mtimeMs }))
      .sort((a, b) => b.mtime - a.mtime)[0]?.name;
  if (!nsisExe) {
    throw new Error(`Expected NSIS installer not found in: ${nsisDir}`);
  }

  const setupSrc = path.join(nsisDir, nsisExe);
  const setupDst = path.join(releaseDir, `OmniSNS-${version}-win-x64-setup.exe`);
  fs.copyFileSync(setupSrc, setupDst);

  const portableSize = fs.statSync(portableDst).size;
  const setupSize = fs.statSync(setupDst).size;

  console.log('');
  console.log('[dist:win] Tauri Windows build artifacts ready:');
  console.log(`  - Installer : ${setupDst} (${formatMB(setupSize)})`);
  console.log(`  - Portable  : ${portableDst} (${formatMB(portableSize)})`);
}

main();
