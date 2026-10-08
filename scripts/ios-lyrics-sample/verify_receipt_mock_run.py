"""Before live execution, require actual same-source native mock receipt success."""
import json, os, pathlib, subprocess, urllib.request
repo = os.environ['GITHUB_REPOSITORY']
assert repo == 'c63amg77771717-commits/spotube'
run_id = os.environ['EVANTUBE_RECEIPT_MOCK_RUN']
assert run_id.isdigit(), 'Provide the completed native recorder/mock validation run ID'
base = 'https://api.github.com/repos/' + repo
def get(path):
    request = urllib.request.Request(base + path, headers={'Authorization': 'Bearer ' + os.environ['GH_TOKEN'], 'Accept': 'application/vnd.github+json'})
    with urllib.request.urlopen(request, timeout=20) as response:
        return json.load(response)
run = get('/actions/runs/' + run_id)
assert run['head_sha'] == os.environ['GITHUB_SHA'] and run['status'] == 'completed' and run['conclusion'] == 'success'
assert run['path'] == '.github/workflows/evantube-native-ios-ipa.yml'
assert any(job['name'] == 'lyrics_receipt_validation' and job['conclusion'] == 'success' for job in get('/actions/runs/' + run_id + '/jobs')['jobs'])
directory = pathlib.Path(os.environ['RUNNER_TEMP']) / 'verified-native-receipt-mocks'
directory.mkdir(exist_ok=False)
subprocess.run(['gh', 'run', 'download', run_id, '--repo', repo, '--name', 'EvanTube-native-lyrics-receipt', '--dir', str(directory)], check=True)
checks = json.loads((directory / 'native-mock-validation.json').read_text(encoding='utf8'))
native = json.loads((directory / 'native-fixed40-mock-receipt.json').read_text(encoding='utf8'))
assert checks['validation'] == 'PASS' and checks['samples'] == 40 and checks['evidenceKind'] == 'nativeMockResponses'
assert checks['automaticTimedRate'] is None
assert native['nativeCheckoutSHA'] == os.environ['GITHUB_SHA'] and native['realProviderQueries'] is False
print(json.dumps({'sameSourceNativeMockValidated': True, 'mockRunID': run_id, 'liveQueriesFromThisCheck': 0}))
