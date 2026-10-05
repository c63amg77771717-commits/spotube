"""Export complete result bundles independently; preserve partial export failures."""
import argparse, json, pathlib, subprocess
p=argparse.ArgumentParser()
p.add_argument('--results-root',type=pathlib.Path,required=True)
p.add_argument('--evidence',type=pathlib.Path,required=True)
p.add_argument('--prefix',default='evantube-')
a=p.parse_args(); a.evidence.mkdir(parents=True,exist_ok=True)
rows=[]
for bundle in sorted(a.results_root.glob(a.prefix+'*.xcresult')):
    target=a.evidence/bundle.stem; target.mkdir(parents=True,exist_ok=True)
    summary=subprocess.run(['xcrun','xcresulttool','get','test-results','summary','--path',str(bundle)],text=True,capture_output=True)
    (target/'summary.stderr.log').write_text(summary.stderr,encoding='utf-8')
    (target/'summary.json').write_text(summary.stdout,encoding='utf-8')
    if summary.returncode:
        rows.append({'bundle':bundle.name,'status':'INCOMPLETE','summary_exit':summary.returncode})
        continue
    exported=subprocess.run(['xcrun','xcresulttool','export','attachments','--path',str(bundle),'--output-path',str(target/'attachments')],text=True,capture_output=True)
    (target/'export.stdout.log').write_text(exported.stdout,encoding='utf-8')
    (target/'export.stderr.log').write_text(exported.stderr,encoding='utf-8')
    rows.append({'bundle':bundle.name,'status':'PASS' if exported.returncode==0 else 'FAIL','export_exit':exported.returncode,'png_count':len(list(target.rglob('*.png'))),'text_count':len(list(target.rglob('*.txt')))})
(a.evidence/'export-status.json').write_text(json.dumps(rows,indent=2),encoding='utf-8')
print(json.dumps(rows,indent=2))
raise SystemExit(0 if any(r['status']=='PASS' for r in rows) and not any(r['status']=='FAIL' for r in rows) else 1)
