# kipuka.dev

The documentation site deploys from the private `czinda/kipuka-dev` GitHub repository
to the `kipuka-dev` Cloudflare Worker. Pushes to **main** run **npm run build**, validate
the generated pages, then run **npx wrangler deploy**. Build caching is enabled.

`KIPUKA_REF` pins the public `czinda/kipuka` source revision used for Rust API docs.
Update that file to publish API changes; source-repo commits alone do not rebuild this site.
The cloud build installs pinned mdBook/Mermaid/Rust tooling and uses locked vendored OpenSSL
for rustdoc. The Linux build installs libclang for native OpenSSL bindings. Generated
output and the source checkout stay under ignored directories.

```bash
npm ci
npm run build
npm run dev
npm run smoke -- https://kipuka.dev "$(git rev-parse HEAD)"
```

Local builds need mdBook 0.5.3, mdbook-mermaid 0.17.1, a C compiler, Perl, and CMake.
Linux cloud builds install the documentation tools automatically. `/build-info.json`
identifies the site and API revisions actually served.

`kipuka.dev` is a native Worker custom domain. The old Cloudflare Pages project is retired.
Rollback by reverting a Git commit or selecting a previous Worker version.
The `origin` remote remains the original GitLab repository; use `git push github main`
for production website releases. Verify the **Workers Builds: kipuka-dev** GitHub check
and the commit in `/build-info.json` after publishing.
