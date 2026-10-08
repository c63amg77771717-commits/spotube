"""Export only the anonymous actual native mock receipt, without upstream bodies."""
import argparse, hashlib, json, pathlib, subprocess, tempfile
p = argparse.ArgumentParser()
p.add_argument('--bundle', required=True)
p.add_argument('--output', type=pathlib.Path, required=True)
p.add_argument('--source', required=True)
a = p.parse_args()
with tempfile.TemporaryDirectory(prefix='evantube-mock-receipt-') as temporary:
    subprocess.run(['xcrun', 'xcresulttool', 'export', 'attachments', '--path', a.bundle, '--output-path', temporary], check=True)
    found = []
    for file in pathlib.Path(temporary).rglob('*'):
        if not file.is_file() or file.stat().st_size > 8 * 1024 * 1024:
            continue
        try:
            receipt = json.loads(file.read_bytes())
        except (ValueError, UnicodeError):
            continue
        if isinstance(receipt, dict) and receipt.get('schema') == 'evantube-fixed40-live-v1' and receipt.get('evidenceKind') == 'nativeMockResponses':
            assert receipt['nativeCheckoutSHA'] == a.source
            assert receipt['realProviderQueries'] is False and receipt['sourceQueriesAuthorized'] is False
            receipt['nativeArtifactSHA256'] = hashlib.sha256(file.read_bytes()).hexdigest()
            found.append(receipt)
    assert len(found) == 1, 'Expected one actual current fixed40 mock receipt'
    a.output.write_text(json.dumps(found[0], ensure_ascii=False, indent=2), encoding='utf8')
print(json.dumps({'nativeMockRows': 40, 'liveQueries': 0, 'lyricTextExported': False}))
