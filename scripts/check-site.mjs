import assert from 'node:assert/strict';
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
const required = ['index.html','favicon.svg','doc/index.html','doc/quickstart/install.html','doc/operator/configuration.html',
  'api/index.html','api/kipuka/index.html','api/kipuka_est/index.html','api/kipuka_util/index.html',
  'api/kipuka_coap/index.html','api/kipuka_dogtag/index.html','api/kipuka_hsm/index.html','api/kipuka_otp/index.html'];
for (const path of required) assert.ok(statSync(join('deploy',path)).size > 0, `Missing ${path}`);
const info = JSON.parse(readFileSync('deploy/build-info.json','utf8'));
assert.match(info.site_commit,/^[0-9a-f]{40}$/); assert.match(info.api_commit,/^[0-9a-f]{40}$/);
let files=0;
function visit(dir) {
  for (const entry of readdirSync(dir,{withFileTypes:true})) {
    const path=join(dir,entry.name);
    if(entry.isDirectory()) visit(path);
    else { assert.ok(entry.isFile()); assert.ok(statSync(path).size <= 25*1024*1024, `Oversized asset: ${path}`); files++; }
  }
}
visit('deploy'); assert.ok(files<=20000,`Too many assets: ${files}`);
console.log(`Validated ${required.length} entry points and ${files} static assets.`);
