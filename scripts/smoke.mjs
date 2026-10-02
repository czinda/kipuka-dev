import assert from 'node:assert/strict';
const [base='https://kipuka.dev',expectedCommit]=process.argv.slice(2);
for(const [path,marker] of [['/','EST enrollment server'],['/doc/','kipuka documentation'],['/doc/quickstart/install.html','Installation'],['/api/','Rust API reference'],['/api/kipuka_est/','kipuka_est']]) {
  const r=await fetch(new URL(path,base),{signal:AbortSignal.timeout(20000)});
  assert.equal(r.status,200,path); assert.ok((await r.text()).includes(marker),`Incorrect content: ${path}`);
}
const r=await fetch(new URL('/build-info.json',base),{cache:'no-store',signal:AbortSignal.timeout(20000)});
assert.equal(r.status,200);const info=await r.json();if(expectedCommit)assert.equal(info.site_commit,expectedCommit);
console.log(`Smoke checks passed: ${base} · ${JSON.stringify(info)}`);
