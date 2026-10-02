import { execFileSync } from 'node:child_process';
import { writeFileSync } from 'node:fs';
writeFileSync('deploy/build-info.json', JSON.stringify({
  site_commit: execFileSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }).trim(),
  api_commit: process.argv[2], built_at: new Date().toISOString(),
}, null, 2) + '\n');
