"""Generate non-secret source provenance as a temporary native test resource."""
import json, os, pathlib, re, subprocess

assert os.environ.get('GITHUB_REPOSITORY') == 'c63amg77771717-commits/spotube'
sha = os.environ['GITHUB_SHA']
assert re.fullmatch('[0-9a-f]{40}', sha)
assert subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip() == sha
repo = pathlib.Path(__file__).resolve().parents[2]
path = repo / 'native-ios/EvanTubeTests/Fixtures/lyrics_receipt_run_context.json'
assert not path.exists(), 'Generated resource must never be retained in source'
path.write_text(json.dumps({'nativeCheckoutSHA': sha, 'nativeRunID': os.environ['GITHUB_RUN_ID']}, indent=2), encoding='utf8')
print(json.dumps({'receiptSourceSHA': sha, 'privateMetadataWritten': False}))
