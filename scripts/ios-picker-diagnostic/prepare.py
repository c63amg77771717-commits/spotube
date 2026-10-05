import argparse, hashlib, json, pathlib, subprocess, plistlib
p=argparse.ArgumentParser()
p.add_argument('--repo',type=pathlib.Path,required=True)
p.add_argument('--evidence',type=pathlib.Path,required=True)
a=p.parse_args(); a.evidence.mkdir(parents=True,exist_ok=True)
files=list((a.repo/'native-ios/LovelyMusicUITests').glob('*.swift'))
before={str(f.relative_to(a.repo)):hashlib.sha256(f.read_bytes()).hexdigest() for f in files}
secrets=a.repo/'native-ios/LovelyMusic/Resources/Secrets.plist'
template=a.repo/'native-ios/Secrets.plist.example'
value=plistlib.loads(secrets.read_bytes() if secrets.exists() else template.read_bytes()); value.pop('YOUTUBE_DATA_API_KEY',None)
secrets.write_bytes(plistlib.dumps(value))
assert before=={str(f.relative_to(a.repo)):hashlib.sha256(f.read_bytes()).hexdigest() for f in files}
receipt={'source_sha':subprocess.check_output(['git','rev-parse','HEAD'],cwd=a.repo,text=True).strip(),'native_subtree':subprocess.check_output(['git','rev-parse','HEAD:native-ios'],cwd=a.repo,text=True).strip(),'test_source_sha256':before,'original_test_sources_unchanged':True,'production_source_unmodified':True,'mode':'Original UI actions and assertions; no injected hit probes'}
(a.evidence/'source-receipt.json').write_text(json.dumps(receipt,indent=2),encoding='utf-8')
print(json.dumps(receipt,indent=2))
