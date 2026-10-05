import argparse, hashlib, json, pathlib, subprocess
p=argparse.ArgumentParser()
p.add_argument('--repo',type=pathlib.Path,required=True)
p.add_argument('--evidence',type=pathlib.Path,required=True)
p.add_argument('--variant',choices=['baseline','label-identifier'],default='baseline')
a=p.parse_args(); a.evidence.mkdir(parents=True,exist_ok=True)
header=a.repo/'native-ios/LovelyMusic/Presentation/Player/Components/SyncedLyricsScrollView.swift'
header_before=header.read_bytes()
if a.variant=='label-identifier':
    old='                        .contentShape(Rectangle())\n                }\n                .accessibilityIdentifier("lyrics_version_picker")'
    new='                        .contentShape(Rectangle())\n                        .accessibilityIdentifier("lyrics_version_picker")\n                }'
    value=header.read_text(encoding='utf-8')
    assert value.count(old)==1
    header.write_text(value.replace(old,new),encoding='utf-8')
file=a.repo/'native-ios/LovelyMusicUITests/EvanTubeLyricsCandidateUITests.swift'
before=file.read_bytes(); text=file.read_text(encoding='utf-8')
marker='''        attachment.name = "lyrics-candidate-menu-touch-target"
        attachment.lifetime = .keepAlways
        add(attachment)'''
assert text.count(marker)==1
replacement=marker+'''
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "lyrics-candidate-accessibility-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        let picker = app.buttons["lyrics_version_picker"]
        let report = "picker frame=\\(picker.frame), exists=\\(picker.exists), enabled=\\(picker.isEnabled), hittable=\\(picker.isHittable), label=\\(picker.label); header frame=\\(app.descendants(matching: .any)[\"lyrics_status_header\"].firstMatch.frame); app frame=\\(app.frame)"
        let inner = picker.buttons.firstMatch
        let innerState = inner.exists ? "inner frame=\\(inner.frame), enabled=\\(inner.isEnabled), hittable=\\(inner.isHittable)" : "inner absent"
        let close = app.buttons["Close player"]
        print("EVANTUBE_PICKER_INNER " + innerState + "; close hittable=\\(close.isHittable)")
        print("EVANTUBE_PICKER_DIAGNOSTIC " + report)
        let geometry = XCTAttachment(string: report)
        geometry.name = "lyrics-candidate-geometry-and-hit-test"
        geometry.lifetime = .keepAlways
        add(geometry)'''
file.write_text(text.replace(marker,replacement),encoding='utf-8')
secrets=a.repo/'native-ios/LovelyMusic/Resources/Secrets.plist'
import plistlib
template=a.repo/'native-ios/Secrets.plist.example'
value=plistlib.loads(secrets.read_bytes() if secrets.exists() else template.read_bytes()); value.pop('YOUTUBE_DATA_API_KEY',None)
secrets.write_bytes(plistlib.dumps(value))
receipt={'source_sha':subprocess.check_output(['git','rev-parse','HEAD'],cwd=a.repo,text=True).strip(),'native_subtree':subprocess.check_output(['git','rev-parse','HEAD:native-ios'],cwd=a.repo,text=True).strip(),'test_helper_before_sha256':hashlib.sha256(before).hexdigest(),'test_helper_after_sha256':hashlib.sha256(file.read_bytes()).hexdigest(),'variant':a.variant,'header_before_sha256':hashlib.sha256(header_before).hexdigest(),'header_after_sha256':hashlib.sha256(header.read_bytes()).hexdigest(),'assertions_preserved':True,'mode':'Debug fixture diagnostics only; no packaged IPA claim'}
(a.evidence/'source-receipt.json').write_text(json.dumps(receipt,indent=2),encoding='utf-8')
print(json.dumps(receipt,indent=2))
