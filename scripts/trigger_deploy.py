"""Use a native push build when present; otherwise trigger the main-branch hook."""
import json
import os
import re
import time
import urllib.error
import urllib.parse
import urllib.request

def native_build():
    if os.environ.get('GITHUB_EVENT_NAME') != 'push':
        return None
    time.sleep(15)
    url = f"https://api.github.com/repos/{os.environ['GITHUB_REPOSITORY']}/commits/{os.environ['GITHUB_SHA']}/check-runs"
    req = urllib.request.Request(url, headers={'Authorization': 'Bearer ' + os.environ['GH_TOKEN'], 'Accept': 'application/vnd.github+json', 'User-Agent': 'kipuka-deploy/1.0'})
    with urllib.request.urlopen(req, timeout=30) as response:
        checks = json.load(response)['check_runs']
    for check in checks:
        if check['name'] != 'Workers Builds: kipuka-dev':
            continue
        if check['status'] == 'completed' and check['conclusion'] != 'success':
            raise SystemExit('The native Workers Build failed. Inspect its GitHub check.')
        match = re.search(r'/builds/([0-9a-f-]{36})$', check.get('details_url', ''))
        if match:
            return match[1]
    return None

def main():
    build = native_build()
    if not build:
        hook = os.environ.get('CLOUDFLARE_DEPLOY_HOOK', '')
        url = urllib.parse.urlsplit(hook)
        if url.scheme != 'https' or url.netloc != 'api.cloudflare.com' or not url.path.startswith('/client/v4/workers/builds/deploy_hooks/'):
            raise SystemExit('Configure the CLOUDFLARE_DEPLOY_HOOK repository secret.')
        try:
            req = urllib.request.Request(hook, method='POST', data=b'{}', headers={'Content-Type':'application/json'})
            with urllib.request.urlopen(req, timeout=30) as response: result = json.load(response)
            build = result['result']['build_uuid']
        except Exception:
            raise SystemExit('Could not trigger deployment. Check the hook secret; its URL is intentionally not logged.') from None
    print(f'Waiting for build {build} to publish.', flush=True)
    deadline = time.monotonic() + 22 * 60
    while time.monotonic() < deadline:
        try:
            req = urllib.request.Request('https://kipuka.dev/build-info.json?verify=' + build,
                headers={'User-Agent':'kipuka-deploy/1.0', 'Cache-Control':'no-cache'})
            with urllib.request.urlopen(req, timeout=20) as response: info = json.load(response)
            if info.get('build_uuid') == build:
                print(f"Published {info['site_commit']} at {info['built_at']}.")
                return
        except (urllib.error.URLError, ValueError, TimeoutError):
            pass
        time.sleep(20)
    raise SystemExit('The expected build was not published within 22 minutes. Inspect Workers Builds.')

if __name__ == '__main__': main()
