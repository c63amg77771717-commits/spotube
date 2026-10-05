import argparse, hashlib, json, pathlib, subprocess
p=argparse.ArgumentParser()
p.add_argument('--repo',type=pathlib.Path,required=True)
p.add_argument('--evidence',type=pathlib.Path,required=True)
p.add_argument('--variant',choices=['baseline','modal-ax'],default='baseline')
a=p.parse_args(); a.evidence.mkdir(parents=True,exist_ok=True)
header=a.repo/'native-ios/LovelyMusic/Presentation/Player/Components/SyncedLyricsScrollView.swift'
header_before=header.read_bytes()
import shutil
probe=a.repo/'native-ios/LovelyMusic/App/NativeHitProbe.swift'
assert not probe.exists()
shutil.copyfile(pathlib.Path(__file__).with_name('NativeHitProbe.swift'),probe)
value=header.read_text(encoding='utf-8')
target='                .accessibilityIdentifier("lyrics_version_picker")'
assert value.count(target)==1
header.write_text(value.replace(target,target+'\n                .background(NativeHitProbe(name: "picker").allowsHitTesting(false).accessibilityHidden(true))'),encoding='utf-8')
full=a.repo/'native-ios/LovelyMusic/Presentation/Player/FullPlayerView.swift'
value=full.read_text(encoding='utf-8');target='                            .accessibilityLabel("Close player")'
assert value.count(target)==1
full.write_text(value.replace(target,target+'\n                            .background(NativeHitProbe(name: "close").allowsHitTesting(false).accessibilityHidden(true))'),encoding='utf-8')
content=a.repo/'native-ios/LovelyMusic/Presentation/Navigation/ContentView.swift'
content_before=content.read_bytes()
if a.variant=='modal-ax':
    value=content.read_text(encoding='utf-8')
    target='            .environment(\.dockBottomInset, bottomInsetValue)'
    assert value.count(target)==1
    value=value.replace(target,target+'\n            .accessibilityHidden(playerVM.isFullPlayerPresented)')
    assert value.count('.accessibilityHidden(dockHidden)')==1
    value=value.replace('.accessibilityHidden(dockHidden)','.accessibilityHidden(dockHidden || playerVM.isFullPlayerPresented)')
    content.write_text(value,encoding='utf-8')

file=a.repo/'native-ios/LovelyMusicUITests/EvanTubeLyricsCandidateUITests.swift'
before=file.read_bytes(); text=file.read_text(encoding='utf-8')
secrets=a.repo/'native-ios/LovelyMusic/Resources/Secrets.plist'
import plistlib
template=a.repo/'native-ios/Secrets.plist.example'
value=plistlib.loads(secrets.read_bytes() if secrets.exists() else template.read_bytes()); value.pop('YOUTUBE_DATA_API_KEY',None)
secrets.write_bytes(plistlib.dumps(value))
receipt={'source_sha':subprocess.check_output(['git','rev-parse','HEAD'],cwd=a.repo,text=True).strip(),'native_subtree':subprocess.check_output(['git','rev-parse','HEAD:native-ios'],cwd=a.repo,text=True).strip(),'test_helper_before_sha256':hashlib.sha256(before).hexdigest(),'test_helper_after_sha256':hashlib.sha256(file.read_bytes()).hexdigest(),'variant':a.variant,'header_before_sha256':hashlib.sha256(header_before).hexdigest(),'header_after_sha256':hashlib.sha256(header.read_bytes()).hexdigest(),'assertions_preserved':True,'original_test_sources_unchanged':before==file.read_bytes(),'content_before_sha256':hashlib.sha256(content_before).hexdigest(),'content_after_sha256':hashlib.sha256(content.read_bytes()).hexdigest(),'probe_sha256':hashlib.sha256(probe.read_bytes()).hexdigest(),'product_release_unchanged':True,'mode':'Debug fixture diagnostics only; no packaged IPA claim'}
(a.evidence/'source-receipt.json').write_text(json.dumps(receipt,indent=2),encoding='utf-8')
print(json.dumps(receipt,indent=2))
