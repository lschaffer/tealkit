const fs = require('fs');
const path = require('path');

const extRoot = path.resolve(__dirname, '..');
const repoRoot = path.resolve(extRoot, '..');

// 1. Copy starter coding skills into ./skills
const srcSkillsDir = path.join(repoRoot, 'cli', 'skills');
const destSkillsDir = path.join(extRoot, 'skills');
fs.mkdirSync(destSkillsDir, { recursive: true });

for (const skillFile of ['coding-agent-skill.md', 'dotnet-engineer-skill.md']) {
  const src = path.join(srcSkillsDir, skillFile);
  const dest = path.join(destSkillsDir, skillFile);
  if (fs.existsSync(src)) {
    fs.copyFileSync(src, dest);
    console.log(`[prepare-bundle] Synced skills/${skillFile}`);
  }
}

// 2. Copy native CLI binary into ./bin for VSIX packaging
const destBinDir = path.join(extRoot, 'bin');
fs.mkdirSync(destBinDir, { recursive: true });

const winExeCandidates = [
  path.join(repoRoot, 'cli', 'build', 'cli', 'windows_x64', 'bundle', 'bin', 'tealkit.exe'),
  path.join(repoRoot, 'cli', 'build', 'cli', 'bundle', 'bin', 'tealkit.exe'),
  path.join(repoRoot, 'cli', 'tealkit.exe'),
];
const winSrc = winExeCandidates.find((p) => fs.existsSync(p));
if (winSrc) {
  const destExe = path.join(destBinDir, 'tealkit.exe');
  fs.copyFileSync(winSrc, destExe);
  const mb = (fs.statSync(destExe).size / (1024 * 1024)).toFixed(2);
  console.log(`[prepare-bundle] Bundled bin/tealkit.exe (${mb} MB) from ${path.relative(repoRoot, winSrc)}`);
} else {
  console.warn('[prepare-bundle] WARNING: cli/tealkit.exe not found; skipping Windows binary copy.');
}

// 3. Copy lightweight sqlite3 native asset (required by sqlite3 3.x @Native relative ../lib/sqlite3.dll lookup)
const sqliteDllCandidates = [
  path.join(repoRoot, 'cli', 'build', 'cli', 'windows_x64', 'bundle', 'lib', 'sqlite3.dll'),
  path.join(repoRoot, 'cli', 'build', 'cli', 'bundle', 'lib', 'sqlite3.dll'),
];
const sqliteDllSrc = sqliteDllCandidates.find((p) => fs.existsSync(p));
if (sqliteDllSrc) {
  const destLibDir = path.join(extRoot, 'lib');
  fs.mkdirSync(destLibDir, { recursive: true });
  const destDll = path.join(destLibDir, 'sqlite3.dll');
  fs.copyFileSync(sqliteDllSrc, destDll);
  const mb = (fs.statSync(destDll).size / (1024 * 1024)).toFixed(2);
  console.log(`[prepare-bundle] Bundled lib/sqlite3.dll (${mb} MB) from ${path.relative(repoRoot, sqliteDllSrc)}`);
}
