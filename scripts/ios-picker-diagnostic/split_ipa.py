"""Create bounded artifact transfers without changing the packaged IPA bytes."""
import argparse, hashlib, json, os, pathlib, subprocess
p=argparse.ArgumentParser()
p.add_argument('--ipa',type=pathlib.Path,required=True)
p.add_argument('--output',type=pathlib.Path,required=True)
a=p.parse_args(); assert a.ipa.is_file()
a.output.mkdir(parents=True,exist_ok=True)
manifest=a.output/'manifest.json'; assert not manifest.exists()
parts=[]
with a.ipa.open('rb') as source:
    while data:=source.read(24*1024*1024):
        index=len(parts); assert index<4, 'IPA exceeds this bounded transfer layout; do not silently omit bytes'
        name=f'EvanTube-native-iOS.ipa.part{index:02d}'
        target=a.output/name; assert not target.exists(); target.write_bytes(data)
        parts.append({'index':index,'file':name,'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest()})
assert parts and sum(p['bytes'] for p in parts)==a.ipa.stat().st_size
receipt={'file':a.ipa.name,'bytes':a.ipa.stat().st_size,'sha256':hashlib.file_digest(a.ipa.open('rb'),'sha256').hexdigest(),'source_sha':os.environ.get('GITHUB_SHA'),'parts':parts}
manifest.write_text(json.dumps(receipt,indent=2),encoding='utf-8')
if output:=os.environ.get('GITHUB_OUTPUT'):
    with open(output,'a') as target:
        target.write(f'count={len(parts)}\n')
        for i in range(1,4): target.write(f'has_part_{i}={str(i<len(parts)).lower()}\n')
print(json.dumps(receipt,indent=2))
