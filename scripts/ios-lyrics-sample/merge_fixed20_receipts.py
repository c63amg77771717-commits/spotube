"""Offline merge of the original ordered dual20 actual native receipts."""
import argparse, hashlib, json, pathlib
p = argparse.ArgumentParser()
p.add_argument('--first', required=True, type=pathlib.Path)
p.add_argument('--second', required=True, type=pathlib.Path)
p.add_argument('--output', required=True, type=pathlib.Path)
a = p.parse_args()
batches = [json.loads(path.read_text(encoding='utf8')) for path in [a.first, a.second]]
for batch, value in enumerate(batches, 1):
    assert value['schema'] == 'evantube-fixed20-live-v1' and value['evidenceKind'] == 'nativeActualProviderResponses'
    assert value['batch'] == batch and value['sampleCount'] == 20
    assert value['nativeExecution'] and value['realProviderQueries'] and value['sourceQueriesAuthorized'] and value['probeBothSources'] and value['independentLookups']
    assert [r['sampleKey'] for r in value['rows']] == [f'sample-{i:02d}' for i in range(1, 21)]
assert batches[0]['nativeCheckoutSHA'] == batches[1]['nativeCheckoutSHA']
assert batches[0]['manifestSHA256'] == batches[1]['previousManifestSHA256']
receipt = {'schema': 'evantube-fixed40-live-v1', 'evidenceKind': 'nativeActualProviderResponses',
           'nativeExecution': True, 'sourceQueriesAuthorized': True, 'realProviderQueries': True,
           'probeBothSources': True, 'independentLookups': True,
           'nativeCheckoutSHA': batches[0]['nativeCheckoutSHA'],
           'batchSourceSHA': [b['nativeCheckoutSHA'] for b in batches], 'batchOrder': [1, 2],
           'manifestSHA256': [b['manifestSHA256'] for b in batches], 'nativeRunIDs': [b['nativeRunID'] for b in batches],
           'nativeArtifactSHA256': [hashlib.sha256(path.read_bytes()).hexdigest() for path in [a.first, a.second]],
           'rows': batches[0]['rows'] + batches[1]['rows']}
a.output.write_text(json.dumps(receipt, ensure_ascii=False, indent=2), encoding='utf8')
print(json.dumps({'mergedRows': 40, 'sameSource': True, 'liveAcceptance': 'REQUIRES_VALIDATION'}))
