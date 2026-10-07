"""Local-only draw; this command does not contact lyric services or upload a playlist."""
import argparse, pathlib, zipfile, json, re, random, hashlib, collections, unicodedata
parser=argparse.ArgumentParser()
parser.add_argument('--source',required=True,type=pathlib.Path)
parser.add_argument('--output',required=True,type=pathlib.Path)
parser.add_argument('--first-results',type=pathlib.Path,help='Actual completed native batch-one JSON; required before drawing batch two')
parser.add_argument('--first-local-audit',type=pathlib.Path,help='Batch-one local population/selection audit')
args=parser.parse_args();source=args.source.resolve();out=args.output.resolve()
assert bool(args.first_results)==bool(args.first_local_audit)
batch=2 if args.first_results else 1
first=json.loads(args.first_results.read_text(encoding='utf-8')) if args.first_results else None
previous=json.loads(args.first_local_audit.read_text(encoding='utf-8')) if args.first_local_audit else None
if first:
 assert first['batch']==1 and first['sampleCount']==20 and len(first['results'])==20
 assert first['nativeExecution'] and first['realProviderQueries'], 'Finish the first actual twenty before drawing the next batch'
 assert first['manifestSHA256']==previous['manifestSHA256']
 assert previous['sourceSHA256']==hashlib.sha256(source.read_bytes()).hexdigest(), 'Do not switch populations between batches'
prior_keys={key for row in first['results'] for key in row['compositionKeys']} if first else set()
prior_ids={row['localVideoID'] for row in previous['selectedLocal']} if previous else set()
def key(text):
 return ''.join(c for c in unicodedata.normalize('NFKD',text.casefold()) if c.isalnum())
def composition_keys(title,artist=''):
 # Deduplication only; never use these projections as provider query metadata.
 value=re.sub(r'(?i)\s*(?:official\s+(?:music\s+video|video|audio|mv|lyrics?\s+video)|lyrics?\s+video|official\s+lyrics?|4k|hd|visualizer)\s*$', '',re.sub(r' [–—－] ', ' - ',title)).strip()
 span=re.search(r'^.+?[【《「\[]([^】》」\]]+)[】》」\]]',value)
 parts=value.split(' - ',1)
 if len(parts)==1 and value!=title.strip():
  whitespace=re.fullmatch(r'([\u3400-\u9fff]{2,4})\s+([^《【]+)',value)
  if whitespace:parts=list(whitespace.groups())
 if span:values=[span.group(1)]
 elif len(parts)==2:
  values=[parts[1]] if artist and key(artist)==key(parts[0]) else [parts[0]] if artist and key(artist)==key(parts[1]) else parts
 else:values=[value]
 projections=[]
 for value in values:
  value=re.sub(r'(?i)\s*[\[(][^\])]*(?:live|remix|acoustic|cover|instrumental|karaoke|demo|remaster|sped\s*up|slowed|nightcore|現場|演唱會|翻唱)[^\])]*[\])]\s*$', '',value).strip()
  projections.append(value)
  bilingual=re.fullmatch(r'([\u3400-\u9fff]+)\s+([A-Za-z][A-Za-z\s\',.?!-]*)',value)
  if bilingual:projections.extend(bilingual.groups())
 return {key(x) for x in projections if key(x)}
assert source.is_file();out.mkdir(parents=True,exist_ok=True)
assert not (out/'query-manifest.json').exists(), 'Keep the existing sample; never redraw after observing failures'
raw=source.read_bytes(); assert len(raw)<=32*1024*1024
if zipfile.is_zipfile(source):
 with zipfile.ZipFile(source) as archive:
  for entry in archive.infolist():
   path=entry.filename.replace('\\','/')
   assert not path.startswith('/') and ':' not in path and '..' not in pathlib.PurePosixPath(path).parts
   assert (entry.external_attr>>16)&0o170000 != 0o120000, 'Match the production unsafe-symlink rejection'
  entries=[x for x in archive.infolist() if x.filename.lower().endswith('.json') and not x.filename.startswith('__MACOSX/')]
  assert len(archive.infolist())<=512 and sum(x.file_size for x in archive.infolist())<=64*1024*1024
  preferred=[x for x in entries if pathlib.PurePosixPath(x.filename).name.lower()=='mb3_all_playlists.json']
  documents=[json.loads(archive.read(x)) for x in preferred[:1] or entries]
else:documents=[json.loads(raw)]
known={'dtVR0oi_N4U','zZmtt5g4tHs','YghlJ-2nvZU','4RVl7b0X88Y','VVVVRl_lG1o','3hw92j4SqrI','gGLp7ht_2bk','oJFEOqekQ7Y','JSMKvZdOmPc','g2R4HuBN7W8','W0b6HramCug','vOM-6qIVyFs'}
def value(x):return str(x).strip() if x is not None and not isinstance(x,(list,dict)) else ''
def stratum(title):
 if re.search('[\u3040-\u30ff]',title):return 'kana-title'
 if re.search('[\uac00-\ud7af]',title):return 'hangul-title'
 if len(re.findall('[\u3400-\u9fff]',title))>=2:return 'han-title-proxy'
 if re.search('[A-Za-z]',title):return 'latin-title'
 return 'other-title'
population=[];excluded=[];seen=set();seen_compositions=set()
for document in documents:
 rows=document.get('songs',[]);assert len(rows)<=20000
 for index,row in enumerate(rows):
  video=value(row.get('youtube_id',row.get('videoId',row.get('video_id'))))
  title=next((value(row.get(k)) for k in ['title','title_raw','name'] if value(row.get(k))), '')
  artist=value(row.get('artist',row.get('artist_name')))
  keys=composition_keys(title,artist)
  reason=None
  if not re.fullmatch('[A-Za-z0-9_-]{11}',video):reason='invalid-playable-id'
  elif video in seen:reason='duplicate-recording'
  elif video in known:reason='known-regression-kept-separate'
  elif video in prior_ids:reason='already-tested-recording'
  elif keys&prior_keys:reason='already-tested-composition'
  elif keys&seen_compositions:reason='duplicate-composition-proxy'
  elif not title or title==video:reason='no-title-do-not-send-video-id'
  elif any('://' in s or any(ord(c)<32 for c in s) for s in [title,artist]):reason='non-metadata-or-control-text'
  seen.add(video)
  if reason:excluded.append({'inputIndex':index,'localVideoID':video,'reason':reason});continue
  duration=value(row.get('duration_seconds'))
  item={'title':title,'artist':artist,'stratum':stratum(title),'localVideoID':video,'inputIndex':index}
  if re.fullmatch('-?[0-9]+',duration):item['duration']=int(duration)
  item['compositionKeys']=sorted(keys);seen_compositions.update(item['compositionKeys'])
  population.append(item)
assert len(population)>=20, 'Need at least twenty eligible unique new recordings; do not substitute known successful fixtures'
# Population order and input fingerprint are saved before any availability is known.
seed=20261006;rng=random.Random(seed+batch-1);han=[x for x in population if x['stratum']=='han-title-proxy'];other=[x for x in population if x['stratum']!='han-title-proxy']
han_count=min(16,len(han));other_count=min(20-han_count,len(other));han_count=min(20-other_count,len(han))
selected=rng.sample(han,han_count)+rng.sample(other,other_count);assert len(selected)==20
rng.shuffle(selected)
samples=[{**{k:v for k,v in x.items() if k in ['title','artist','duration','stratum']},'sampleKey':f'sample-{i+1:02d}'} for i,x in enumerate(selected)]
manifest={'seed':seed,'batch':batch,'drawSeed':seed+batch-1,'previousManifestSHA256':first['manifestSHA256'] if first else None,'samples':samples,'strata':dict(collections.Counter(x['stratum'] for x in samples))}
digest=hashlib.sha256(json.dumps(manifest,ensure_ascii=False,sort_keys=True,separators=(',',':')).encode()).hexdigest();manifest['manifestSHA256']=digest
(out/'population-local-only.json').write_text(json.dumps({'source':str(source),'sourceSHA256':hashlib.sha256(raw).hexdigest(),'seed':seed,'batch':batch,'manifestSHA256':digest,'population':population,'exclusions':excluded,'selectedLocal':selected,'stratificationNote':'Title script is a declared language proxy, not verified song language','deduplicationNote':'Conservative normalized title/span/bilingual/version projections ignore performers to avoid selecting covers or alternate recordings as new compositions. Projection ambiguity is checked again through production canonical metadata before any live query. This is not proof of every translated title equivalence.'},ensure_ascii=False,indent=2),encoding='utf-8')
(out/'query-manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps({'seed':seed,'batch':batch,'eligiblePopulation':len(population),'selected':20,'strata':manifest['strata'],'manifestSHA256':digest,'networkRequests':0,'localOnlyPopulation':True,'queryManifestOmitsIDsAccountsAndPlaylistNames':True}))
