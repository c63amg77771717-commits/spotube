"""Deterministic invented test data; no export or playlist is an input."""
import hashlib
import json


def encoded(value):
    return (json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode('utf8')


def synthetic_manifests():
    documents = []
    for batch in (1, 2):
        samples = []
        for index in range(1, 21):
            number = (batch - 1) * 20 + index
            title = f'Synthetic Track {number:02d}'
            artist = f'Synthetic Performer {number:02d}'
            stratum = 'latin-title'
            if index % 4 == 0:
                title = f'Synthetic Performer {number:02d} - Synthetic Track {number:02d} (Lyrics) ft. Synthetic Guest {number:02d}'
                artist = ''
                stratum = 'collaboration-credit'
            elif index % 4 == 1:
                title = f'合成歌曲{number:02d}'
                artist = f'合成演唱者{number:02d}'
                stratum = 'cjk-title'
            samples.append({'sampleKey': f'sample-{index:02d}', 'title': title, 'artist': artist,
                            'duration': 180 + number, 'stratum': stratum})
        document = {'dataOrigin': 'entirelySynthetic', 'schema': 'evantube-public-synthetic20-v1',
                    'batch': batch, 'seed': 0, 'drawSeed': 0, 'samples': samples,
                    'previousManifestSHA256': documents[0]['manifestSHA256'] if documents else None}
        document['manifestSHA256'] = hashlib.sha256(json.dumps(document, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
        documents.append(document)
    return documents
