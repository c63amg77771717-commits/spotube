"""Read-only same-commit validation; fail before any Release build or IPA packaging."""
import os,json,pathlib,urllib.request,re
sha=os.environ['EVANTUBE_EXPECTED_SHA'];assert re.fullmatch('[0-9a-f]{40}',sha)
repo=os.environ.get('GITHUB_REPOSITORY');assert repo=='c63amg77771717-commits/spotube'
assert os.environ.get('EVANTUBE_SAMPLE_PASSED')=='success', 'The authorized fixed sample has not passed in this run'
base='https://api.github.com/repos/'+repo
def get(path):
 request=urllib.request.Request(base+path,headers={'Authorization':'Bearer '+os.environ['GH_TOKEN'],'Accept':'application/vnd.github+json'})
 with urllib.request.urlopen(request,timeout=20) as response:return json.load(response)
assert get('')['private'] is False, 'This task authorizes only free public-repository standard runners'
branch='codex/ios-neonoir-20260930'
assert get('/branches/codex%2Fios-neonoir-20260930')['commit']['sha']==sha, 'Do not package an obsolete branch revision'
verified=[]
for workflow,artifact in [('evantube-agent-device-ios.yml','EvanTube-build20-agent-device-evidence'),('evantube-picker-diagnostic.yml','EvanTube-build19-picker-diagnostic')]:
 runs=get('/actions/workflows/'+workflow+'/runs?branch=codex%2Fios-neonoir-20260930&per_page=100')['workflow_runs']
 matches=[x for x in runs if x['head_sha']==sha and x['head_branch']==branch]
 assert matches, 'No matching same-commit test run: '+workflow
 run=max(matches,key=lambda x:(x['run_number'],x.get('run_attempt',1)))
 assert run['status']=='completed' and run['conclusion']=='success', 'Test is incomplete or failed: '+run['html_url']
 artifacts=get('/actions/runs/'+str(run['id'])+'/artifacts')['artifacts']
 assert any(x['name']==artifact and not x['expired'] for x in artifacts), 'Missing current evidence: '+workflow
 verified.append({'workflow':workflow,'runID':run['id'],'attempt':run.get('run_attempt',1),'source':run['head_sha'],'url':run['html_url']})
result_path=pathlib.Path(os.environ['RUNNER_TEMP'])/'evantube-random-sample.json'
sample=json.loads(result_path.read_text(encoding='utf-8'))
manifest=json.loads(pathlib.Path('native-ios/EvanTubeTests/Fixtures/authorized_random_lyrics_sample.json').read_text(encoding='utf-8'))
assert sample['batch']==2, 'Final packaging requires the second twenty-song batch'
first=json.loads((pathlib.Path(os.environ['RUNNER_TEMP'])/'evantube-first-sample.json').read_text(encoding='utf-8'))
assert first['batch']==1 and first['sampleCount']==20 and len(first['results'])==20
assert first['nativeExecution'] and first['realProviderQueries'] and first['realProviderResponses']
assert first['manifestSHA256']==sample['previousManifestSHA256']==manifest['previousManifestSHA256']
assert sample['sampleCount']==20 and len(sample['results'])==20 and sample['nativeExecution'] and sample['realProviderQueries'] and sample['realProviderResponses']
first_keys={key for row in first['results'] for key in row['compositionKeys']}
second_keys={key for row in sample['results'] for key in row['compositionKeys']}
assert first_keys.isdisjoint(second_keys), 'The two batches must not count alternate video IDs as new songs'
assert sample['manifestSHA256']==manifest['manifestSHA256'] and sample['seed']==20261006
assert [x['index'] for x in sample['results']]==list(range(20))
assert all(x['state'] in ['sourceUnavailable','providerEmpty','candidatesRejected','manualSelection','confirmedPlain','synchronized','metadataRejected'] for x in sample['results'])
assert all(len(x['requests'])<=24 and len(x['providers'])==2 for x in sample['results'])
assert all(all(q['onlyTitleAndArtist'] for q in x['requests']) for x in sample['results'])
assert all(any(p['acceptedCount']>0 for row in batch['results'] for p in row['providers']) for batch in [first,sample]), 'Investigate a batch with no suitable returned lyrics before packaging'
import collections
all_rows=first['results']+sample['results']
stats={'total':40,'states':dict(collections.Counter(row['state'] for row in all_rows)),
       'contentRetrieved':sum(row['contentRetrieved'] for row in all_rows),
       'automaticIdentity':sum(row['automaticIdentity'] for row in all_rows),
       'sourceFailures':sum(provider['failureCount'] for row in all_rows for provider in row['providers'])}
receipt={'source':sha,'sampleStatistics':stats,'sameCommitAgentAndPicker':verified,'sampleManifestSHA256':manifest['manifestSHA256'],'sampleCount':40,'batchCounts':[20,20],'nativeAndUI':'current job succeeded','packageAllowed':True}
(pathlib.Path(os.environ['RUNNER_TEMP'])/'evantube-prepackage-gate.json').write_text(json.dumps(receipt,indent=2),encoding='utf-8')
print(json.dumps(receipt,indent=2))
