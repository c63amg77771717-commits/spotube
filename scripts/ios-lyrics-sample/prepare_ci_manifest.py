"""Validate only the twenty selected metadata rows before adding a test resource."""
import os,json,pathlib,hashlib,re,collections,subprocess,urllib.request
data=json.loads(os.environ['EVANTUBE_SAMPLE_JSON'])
assert set(data)=={'seed','batch','drawSeed','previousManifestSHA256','samples','strata','manifestSHA256'} and data['seed']==20261006
assert data['batch'] in [1,2] and data['drawSeed']==20261006+data['batch']-1
assert isinstance(data['samples'],list) and len(data['samples'])==20
assert [x['sampleKey'] for x in data['samples']]==[f'sample-{i:02d}' for i in range(1,21)]
for row in data['samples']:
 assert set(row).issubset({'title','artist','duration','stratum','sampleKey'})
 assert isinstance(row['title'],str) and row['title'] and len(row['title'])<=4096
 assert isinstance(row['artist'],str) and len(row['artist'])<=4096
 assert all('://' not in x and not any(ord(c)<32 for c in x) for x in [row['title'],row['artist']])
 if 'duration' in row:assert type(row['duration']) is int
assert dict(collections.Counter(x['stratum'] for x in data['samples']))==data['strata']
canonical={k:v for k,v in data.items() if k!='manifestSHA256'}
actual=hashlib.sha256(json.dumps(canonical,ensure_ascii=False,sort_keys=True,separators=(',',':')).encode()).hexdigest()
assert actual==data['manifestSHA256'], 'Use the same fixed sample after failures'
if data['batch']==2:
 run_id=os.environ.get('EVANTUBE_FIRST_SAMPLE_RUN','');assert run_id.isdigit(), 'A successful batch-one run is required before batch two'
 repo=os.environ['GITHUB_REPOSITORY'];assert repo=='c63amg77771717-commits/spotube'
 req=urllib.request.Request('https://api.github.com/repos/'+repo+'/actions/runs/'+run_id,headers={'Authorization':'Bearer '+os.environ['GH_TOKEN'],'Accept':'application/vnd.github+json'})
 with urllib.request.urlopen(req,timeout=20) as response:run=json.load(response)
 assert run['head_sha']==os.environ['EVANTUBE_EXPECTED_SHA'] and run['conclusion']=='success' and run['status']=='completed'
 assert run['path']=='.github/workflows/evantube-native-ios-ipa.yml'
 download=pathlib.Path(os.environ['RUNNER_TEMP'])/'evantube-first-sample';download.mkdir(exist_ok=False)
 subprocess.run(['gh','run','download',run_id,'--repo',repo,'--name','EvanTube-random-lyrics-sample','--dir',str(download)],check=True)
 first=json.loads((download/'evantube-random-sample.json').read_text(encoding='utf-8'))
 assert first['batch']==1 and first['sampleCount']==20 and first['nativeExecution'] and first['realProviderQueries']
 assert first['manifestSHA256']==data['previousManifestSHA256']
 data['priorCompositionKeys']=sorted({key for row in first['results'] for key in row['compositionKeys']})
 data['priorPossibleTitleKeys']=sorted({key for row in first['results'] for key in row.get('possibleTitleKeys',[])})
 (pathlib.Path(os.environ['RUNNER_TEMP'])/'evantube-first-sample.json').write_text(json.dumps(first,ensure_ascii=False,indent=2),encoding='utf-8')
else:assert data['previousManifestSHA256'] is None
dest=pathlib.Path('native-ios/EvanTubeTests/Fixtures/authorized_random_lyrics_sample.json')
assert not dest.exists();dest.write_text(json.dumps(data,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps({'selected':20,'seed':data['seed'],'manifestSHA256':actual,'noVideoIDsAccountsOrPlaylistNames':True,'durationNeverSentToProvider':True}))
