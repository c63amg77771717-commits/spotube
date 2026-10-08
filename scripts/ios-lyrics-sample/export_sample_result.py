import argparse,pathlib,subprocess,json,tempfile
p=argparse.ArgumentParser();p.add_argument('--bundle',required=True,type=pathlib.Path);p.add_argument('--output',required=True,type=pathlib.Path);a=p.parse_args()
with tempfile.TemporaryDirectory(prefix='evantube-sample-export-') as temp:
 subprocess.run(['xcrun','xcresulttool','export','attachments','--path',str(a.bundle),'--output-path',temp],check=True)
 found=[]
 for file in pathlib.Path(temp).rglob('*'):
  if not file.is_file() or file.stat().st_size>8*1024*1024:continue
  try:obj=json.loads(file.read_bytes())
  except (ValueError,UnicodeError):continue
  if isinstance(obj,dict) and obj.get('sampleCount')==20 and obj.get('nativeExecution') is True and obj.get('schema')=='evantube-fixed20-live-v1':found.append(obj)
 assert len(found)==1, 'Expected the actual current native twenty-song sample attachment'
 a.output.write_text(json.dumps(found[0],ensure_ascii=False,indent=2),encoding='utf-8')
 print(json.dumps({'sampleCount':20,'nativeResultAttachmentExported':True}))
