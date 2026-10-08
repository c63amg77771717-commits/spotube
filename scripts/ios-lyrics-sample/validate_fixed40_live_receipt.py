"""Offline verifier for the proposed fixed-40 live receipt; never sends requests.

This is report preparation, not the native recorder. Missing recorder fields FAIL
instead of inferring production coverage from saved candidate metadata.
"""
import argparse
import copy
import hashlib
import json
import math
from collections import Counter
from pathlib import Path

MANIFESTS = [
    ('fixed_lyrics_batch1.json', 'cfd46bc50c5a19e4d0378a5be7ae887cf69f351efa11b9f01561a5f1113a753f', 'cfb9c6e63edc670d55748676d5abdf664b726fbf6749c3edd178b258c1cf0e7a', 'a1a541908b0bc0158c4c3d1f1d69cf1fbc18b1d28000bb9fad14eef3026fdd73'),
    ('fixed_lyrics_batch2.json', 'bd83c61a554d5666edaa2d87ceef21321eb52d0559fc1328076235f906e76dc0', 'fc933e893a1471794ae3df7281a864c946750f973d6db15b55229524e126fae5', '08f2a23b4fbce4cf7a8d446179047aa2c579cb569e90eac3c34667b04290c99b'),
]
PROVIDERS = {'lrclib', 'lrcapi'}
OUTCOMES = {'automaticTimed', 'automaticPlain', 'manualCandidate', 'rejectedCandidates', 'emptyProviderResults', 'sourceUnavailable', 'metadataRejected', 'lookupIncomplete'}
QUERY_OUTCOMES = {'completed', 'failed', 'cancelled', 'malformed', 'truncated', 'notAttempted', 'budgetOmitted', 'earlyReturn'}

def require(value, message):
    if not value:
        raise ValueError(message)

def finite(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) and value >= 0

def sample_digest(sample):
    metadata = {k: sample[k] for k in ['title', 'artist', 'duration', 'stratum', 'sampleKey']}
    return hashlib.sha256(json.dumps(metadata, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode('utf8')).hexdigest()

def load_manifests(directory):
    manifests = []
    for batch, (name, raw_hash, canonical_hash, git_blob_hash) in enumerate(MANIFESTS, 1):
        raw = (Path(directory) / name).read_bytes()
        require(hashlib.sha256(raw).hexdigest() in {raw_hash, git_blob_hash}, 'original manifest changed: ' + name)
        m = json.loads(raw)
        require(m['batch'] == batch and m['seed'] == 20261006, 'wrong batch/seed')
        require(m['manifestSHA256'] == canonical_hash, 'wrong declared manifest identity')
        require(len(m['samples']) == 20, 'manifest must contain original 20')
        require([x['sampleKey'] for x in m['samples']] == [f'sample-{i:02d}' for i in range(1, 21)], 'manifest order changed')
        manifests.append(m)
    require(manifests[1]['previousManifestSHA256'] == manifests[0]['manifestSHA256'], 'broken original chain')
    return manifests

def validate(receipt, manifests, synthetic=False, native_mock=False):
    require(receipt.get('schema') == 'evantube-fixed40-live-v1', 'recorder schema missing')
    require(receipt.get('evidenceKind') == ('syntheticVerifierSelfTest' if synthetic else 'nativeMockResponses' if native_mock else 'nativeActualProviderResponses'), 'not actual native provider evidence')
    require(receipt.get('nativeExecution') is True, 'native execution missing')
    require(receipt.get('sourceQueriesAuthorized') is (not native_mock), 'authorized execution receipt missing')
    require(receipt.get('probeBothSources') is True, 'two-source production route missing')
    require(receipt.get('independentLookups') is True, 'cache/remembered direction isolation missing')
    require(receipt.get('manifestSHA256') == [x[2] for x in MANIFESTS], 'manifest chain differs')
    source = receipt.get('nativeCheckoutSHA', '')
    require(len(source) == 40 and all(c in '0123456789abcdef' for c in source), 'exact native source missing')
    require(receipt.get('batchSourceSHA') == [source, source], 'batches use different native sources')
    require(receipt.get('batchOrder') == [1, 2], 'must execute first 20 before second 20')
    if not synthetic:
        require(receipt.get('nativeRunIDs') and receipt.get('nativeArtifactSHA256'), 'actual native run/artifact provenance missing')
    rows = receipt.get('rows', [])
    require([(x.get('batch'), x.get('sampleKey')) for x in rows] == [(b, f'sample-{i:02d}') for b in (1, 2) for i in range(1, 21)], 'fixed 40 replaced, missing, duplicated, or reordered')
    lookup_ids = set()
    counts = Counter()
    total_attempts = 0
    wall_times = []
    upstream_times = []
    for row in rows:
        prefix = f"batch{row['batch']}/{row['sampleKey']}: "
        original = manifests[row['batch'] - 1]['samples'][int(row['sampleKey'][-2:]) - 1]
        require(row.get('sourceSampleSHA256') == sample_digest(original), prefix + 'original sample metadata changed')
        require(row['outcome'] in OUTCOMES, prefix + 'unknown result classification')
        require(finite(row['lookupWallMilliseconds']), prefix + 'lookup wall timing missing')
        require(row.get('humanVocalAlignment') in {'NOT_RUN', 'PASS', 'FAIL'}, prefix + 'human alignment separate status missing')
        require(row.get('humanRecordingIdentity') in {'NOT_RUN', 'PASS', 'FAIL'}, prefix + 'human recording identity missing')
        if row['humanVocalAlignment'] != 'NOT_RUN' or row['humanRecordingIdentity'] != 'NOT_RUN':
            require(row.get('humanVerificationReceipt'), prefix + 'human outcome needs independent evidence')
        providers = row['directionCoverage']['providers']
        require({p['provider'] for p in providers} == PROVIDERS and len(providers) == 2, prefix + 'per-provider coverage missing')
        required = set(row['directionCoverage']['requiredPairKeys'])
        query_ledger = row['queryLedger']
        require(len({q['queryID'] for q in query_ledger}) == len(query_ledger), prefix + 'duplicate logical query IDs')
        per_attempts = Counter()
        for p in providers:
            require(p.get('capturedFrom') in {'productionLookupReport.directionEvidence', 'productionAdapter.directionCoverage'}, prefix + 'injected/inferred coverage forbidden')
            require(p['lookupID'] not in lookup_ids, prefix + 'coverage reused between provider/song lookups')
            lookup_ids.add(p['lookupID'])
            queries = [q for q in query_ledger if q['provider'] == p['provider']]
            require(all(q['lookupID'] == p['lookupID'] for q in queries), prefix + 'cross-session query evidence')
            require(len([q for q in queries if q['attempts']]) <= 6, prefix + 'production six-query budget exceeded')
            completed = set()
            for q in queries:
                require(q['outcome'] in QUERY_OUTCOMES, prefix + 'query terminal status missing')
                require(q['pairKey'], prefix + 'query pair omitted, including on errors')
                allowed_keys = {'track_name', 'artist_name'} if p['provider'] == 'lrclib' else {'title', 'artist'}
                require(set(q['payloadKeys']) <= allowed_keys, prefix + 'metadata disclosure exceeds title/artist')
                require(q['endpoint'] in ({'/api/get', '/api/search'} if p['provider'] == 'lrclib' else {'/jsonapi'}), prefix + 'unapproved endpoint')
                attempts = q['attempts']
                require(len(attempts) <= 2, prefix + 'unbounded retry')
                require([a['attempt'] for a in attempts] == list(range(1, len(attempts) + 1)), prefix + 'retry numbering inconsistent')
                if q['outcome'] in {'notAttempted', 'budgetOmitted', 'earlyReturn'}:
                    require(not attempts and q['skipReason'], prefix + 'unattempted query needs explicit reason')
                for a in attempts:
                    require(a['scheduledThrottleMilliseconds'] == 500, prefix + 'existing throttle changed')
                    for field in ['throttleMilliseconds', 'upstreamMilliseconds', 'attemptWallMilliseconds', 'localOverheadMilliseconds', 'startMonotonicMilliseconds', 'endMonotonicMilliseconds']:
                        require(finite(a[field]), prefix + field + ' missing/nonfinite')
                    require(a['startMonotonicMilliseconds'] <= a['endMonotonicMilliseconds'], prefix + 'invalid wall timing order')
                    if a['networkStartMonotonicMilliseconds'] is None:
                        require(a['upstreamMilliseconds'] == 0 and (a['cancelled'] or a['transportErrorCode'] is not None), prefix + 'no upstream request needs explicit pre-network failure')
                    else:
                        require(finite(a['networkStartMonotonicMilliseconds']) and a['startMonotonicMilliseconds'] <= a['networkStartMonotonicMilliseconds'] <= a['endMonotonicMilliseconds'], prefix + 'invalid timing order')
                        require(abs(a['networkStartMonotonicMilliseconds'] - a['startMonotonicMilliseconds'] - a['throttleMilliseconds']) <= a['localOverheadMilliseconds'] + 2, prefix + 'throttle interval differs from clock')
                    require(abs(a['attemptWallMilliseconds'] - (a['throttleMilliseconds'] + a['upstreamMilliseconds'] + a['localOverheadMilliseconds'])) <= 2, prefix + '500ms throttle mixed into network time')
                    require(a['httpStatus'] is not None or a['transportErrorCode'] is not None or a['cancelled'], prefix + 'attempt completion reason missing')
                    if a['networkStartMonotonicMilliseconds'] is not None:
                        upstream_times.append(a['upstreamMilliseconds'])
                require(finite(q['retryBackoffMilliseconds']), prefix + 'backoff timing missing')
                require(q['retryBackoffMilliseconds'] <= 5100, prefix + 'production backoff cap exceeded')
                per_attempts[p['provider']] += len(attempts)
                if q['coverageMutation'] == 'recordSuccess':
                    require(q['outcome'] == 'completed' and q['metadataComplete'] is True and 0 <= q['returnedCount'] <= 30 and q['inspectedCount'] == q['returnedCount'], prefix + 'failed/truncated/malformed query falsely proves absence')
                    require(q['endpoint'] != '/api/get', prefix + 'direct get cannot establish direction search coverage')
                    completed.add(q['pairKey'])
                else:
                    require(q['coverageMutation'] in {'recordFailure', 'recordIncomplete', 'none'}, prefix + 'coverage mutation missing')
            require(completed == set(p['completedPairKeys']), prefix + 'completed pair ledger differs from production evidence')
            if any(q['coverageMutation'] in {'recordFailure', 'recordIncomplete'} for q in queries):
                require(p['incomplete'] is True, prefix + 'incomplete query forgotten in production coverage')
            require(p['coversRequiredPairs'] == (not p['incomplete'] and required <= completed), prefix + 'coverage gate differs from production semantics')
        require(set(q['provider'] for q in query_ledger) <= PROVIDERS, prefix + 'unknown provider')
        require(all(n <= 12 for n in per_attempts.values()) and sum(per_attempts.values()) <= 24, prefix + 'request limit exceeded')
        selected = row.get('selected')
        if row['outcome'] == 'automaticTimed':
            require(selected and selected['identityDecision'] == 'confirmed' and selected['timingQualified'] is True and selected['finalScore'] >= 85, prefix + 'final automatic identity/timing gate missing')
            require(selected['selectionEvaluation'] == 'finalComposite', prefix + 'provider pre-coverage trace substituted for final decision')
            if row['directionCoverage']['requiredForAutomatic']:
                require(required and all(p['coversRequiredPairs'] for p in providers), prefix + 'automatic promotion without complete BOTH-provider coverage')
                require(selected['confirmedDirectionHypothesisID'], prefix + 'unique direction decision missing')
        if selected:
            require(selected['qualifiedRecordID'] and selected['contentLineCount'] > 0 and row['contentRetrieved'], prefix + 'actual content evidence missing')
            require(len(selected['contentSHA256']) == 64, prefix + 'content hash missing')
            evidence_query = next((q for q in query_ledger if q['queryID'] == selected['evidenceQueryID']), None)
            require(evidence_query and evidence_query['outcome'] == 'completed' and evidence_query['returnedCount'] > 0, prefix + 'selected record lacks actual source query')
            if selected['timingQualified']:
                require(len(selected['timelineSHA256']) == 64 and selected['timedLineCount'] > 0, prefix + 'actual timed lines missing')
        require(isinstance(row['sourceAvailabilityFailures'], list), prefix + 'source failures must remain distinct from identity outcome')
        counts[row['outcome']] += 1
        wall_times.append(row['lookupWallMilliseconds'])
        total_attempts += sum(per_attempts.values())
    return {'validation': 'PASS', 'evidenceKind': receipt['evidenceKind'], 'samples': 40, 'outcomes': dict(counts), 'requests': total_attempts,
            'automaticTimedRate': None if synthetic or native_mock else counts['automaticTimed'] / 40,
            'humanVocalAlignmentTested': sum(r['humanVocalAlignment'] != 'NOT_RUN' for r in rows),
            'lookupWallMilliseconds': distribution(wall_times), 'upstreamAttemptMilliseconds': distribution(upstream_times),
            'rateMeaning': 'Native policy selection with actual provider responses; not human recording correctness or vocal synchronization.'}

def distribution(values):
    if not values:
        return None
    values = sorted(values)
    return {name: values[max(0, math.ceil(len(values) * percentile) - 1)] for name, percentile in [('p50', .5), ('p95', .95), ('max', 1)]}

def synthetic_receipt(manifests):
    rows = []
    for b in (1, 2):
        for i in range(1, 21):
            providers, ledger = [], []
            for provider in sorted(PROVIDERS):
                lookup = f'{b}/{i}/{provider}'
                providers.append({'provider': provider, 'lookupID': lookup, 'capturedFrom': 'productionLookupReport.directionEvidence', 'completedPairKeys': ['forward', 'reverse'], 'incomplete': False, 'coversRequiredPairs': True})
                for pair in ['forward', 'reverse']:
                    ledger.append({'provider': provider, 'lookupID': lookup, 'queryID': lookup + '/' + pair, 'pairKey': pair, 'endpoint': '/api/search' if provider == 'lrclib' else '/jsonapi', 'payloadKeys': ['track_name', 'artist_name'] if provider == 'lrclib' else ['title', 'artist'], 'outcome': 'completed', 'coverageMutation': 'recordSuccess', 'metadataComplete': True, 'returnedCount': 0, 'inspectedCount': 0, 'retryBackoffMilliseconds': 0, 'attempts': [{'attempt': 1, 'httpStatus': 200, 'transportErrorCode': None, 'cancelled': False, 'scheduledThrottleMilliseconds': 500, 'throttleMilliseconds': 501, 'upstreamMilliseconds': 300, 'localOverheadMilliseconds': 1, 'attemptWallMilliseconds': 802, 'startMonotonicMilliseconds': 0, 'networkStartMonotonicMilliseconds': 501, 'endMonotonicMilliseconds': 802}]})
            rows.append({'batch': b, 'sampleKey': f'sample-{i:02d}', 'sourceSampleSHA256': sample_digest(manifests[b - 1]['samples'][i - 1]), 'outcome': 'emptyProviderResults', 'lookupWallMilliseconds': 3220, 'contentRetrieved': False, 'humanVocalAlignment': 'NOT_RUN', 'humanRecordingIdentity': 'NOT_RUN', 'selected': None, 'sourceAvailabilityFailures': [], 'directionCoverage': {'requiredPairKeys': ['forward', 'reverse'], 'requiredForAutomatic': True, 'providers': providers}, 'queryLedger': ledger})
    return {'schema': 'evantube-fixed40-live-v1', 'evidenceKind': 'syntheticVerifierSelfTest', 'nativeExecution': True, 'sourceQueriesAuthorized': True, 'probeBothSources': True, 'independentLookups': True, 'nativeCheckoutSHA': '0' * 40, 'batchSourceSHA': ['0' * 40] * 2, 'batchOrder': [1, 2], 'manifestSHA256': [m[2] for m in MANIFESTS], 'rows': rows}

def self_test(manifests):
    sample = synthetic_receipt(manifests)
    require(validate(sample, manifests, True)['automaticTimedRate'] is None, 'synthetic test must never report a real rate')
    automatic = copy.deepcopy(sample)
    row = automatic['rows'][0]
    q = row['queryLedger'][2]
    q.update(returnedCount=1, inspectedCount=1)
    row.update(outcome='automaticTimed', contentRetrieved=True, selected={'qualifiedRecordID': 'lrclib:synthetic-1', 'evidenceQueryID': q['queryID'], 'contentLineCount': 2, 'timedLineCount': 2, 'contentSHA256': 'a' * 64, 'timelineSHA256': 'b' * 64, 'identityDecision': 'confirmed', 'timingQualified': True, 'finalScore': 95, 'selectionEvaluation': 'finalComposite', 'confirmedDirectionHypothesisID': 'synthetic-forward'})
    validate(automatic, manifests, True)
    incomplete = copy.deepcopy(automatic)
    row = incomplete['rows'][0]
    q = row['queryLedger'][1]
    q.update(outcome='budgetOmitted', attempts=[], skipReason='six-query-production-budget', coverageMutation='none')
    row['directionCoverage']['providers'][0].update(completedPairKeys=['forward'], coversRequiredPairs=False)
    incomplete_automatic = copy.deepcopy(incomplete)
    row.update(outcome='manualCandidate')
    validate(incomplete, manifests, True)
    changes = {
        'truncated-mislabeled-as-complete': lambda r: r['rows'][0]['queryLedger'][0].update(returnedCount=31, inspectedCount=30),
        'malformed-mislabeled-as-complete': lambda r: r['rows'][0]['queryLedger'][0].update(metadataComplete=False),
        'failed-mislabeled-as-complete': lambda r: r['rows'][0]['queryLedger'][0].update(outcome='failed'),
        'missing-completion-pair': lambda r: r['rows'][0]['directionCoverage']['providers'][0].update(completedPairKeys=['forward']),
        'throttle-in-network-time': lambda r: r['rows'][0]['queryLedger'][0]['attempts'][0].update(upstreamMilliseconds=801),
        'unauthorized-duration': lambda r: r['rows'][0]['queryLedger'][0]['payloadKeys'].append('duration'),
        'swapped-batch-order': lambda r: r.update(batchOrder=[2, 1]),
        'different-source': lambda r: r.update(batchSourceSHA=['0' * 40, '1' * 40]),
        'replaced-or-reordered-sample': lambda r: r['rows'].reverse(),
        'human-sync-without-evidence': lambda r: r['rows'][0].update(humanVocalAlignment='PASS'),
        'coverage-reused': lambda r: r['rows'][1]['directionCoverage']['providers'][0].update(lookupID=r['rows'][0]['directionCoverage']['providers'][0]['lookupID']),
        'fake-live-receipt': lambda r: r.update(evidenceKind='savedMetadataReplay'),
        'original-title-replaced': lambda r: r['rows'][0].update(sourceSampleSHA256='1' * 64),
    }
    checks = []
    for name, mutation in changes.items():
        candidate = copy.deepcopy(sample)
        mutation(candidate)
        try:
            validate(candidate, manifests, True)
        except (ValueError, KeyError, TypeError):
            checks.append({'case': name, 'result': 'PASS-rejected'})
        else:
            raise ValueError('self-test failed to reject ' + name)
    try:
        validate(incomplete_automatic, manifests, True)
    except ValueError:
        checks.append({'case': 'automatic-with-secondary-budget-omission', 'result': 'PASS-rejected'})
    else:
        raise ValueError('automatic incomplete coverage was accepted')
    stale = copy.deepcopy(automatic)
    stale['rows'][0]['selected'].update(selectionEvaluation='providerPreCoverage')
    try:
        validate(stale, manifests, True)
    except ValueError:
        checks.append({'case': 'pre-coverage-score-substituted-for-final', 'result': 'PASS-rejected'})
    else:
        raise ValueError('pre-coverage diagnostic was accepted as final')
    return {'offlineSelfTest': 'PASS', 'positiveCases': ['complete-empty-search-ledger', 'complete-both-provider-automatic-ledger', 'manual-with-incomplete-secondary-ledger'], 'negativeCases': checks, 'providerRequests': 0, 'liveAcceptance': 'NOT_RUN', 'scope': 'Offline verifier self-test; native recorder execution requires its separate Mac evidence', 'automaticTimedRate': None}

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest-directory', required=True)
    parser.add_argument('--receipt', type=Path)
    parser.add_argument('--self-test', action='store_true')
    parser.add_argument('--native-mock', action='store_true', help='Verify actual native mocked responses; never report a live rate')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    manifests = load_manifests(args.manifest_directory)
    require(args.self_test != bool(args.receipt), 'choose one receipt or offline self-test')
    result = self_test(manifests) if args.self_test else validate(json.loads(args.receipt.read_text(encoding='utf8')), manifests, native_mock=args.native_mock)
    output = json.dumps(result, ensure_ascii=False, indent=2)
    if args.output:
        args.output.write_text(output + '\n', encoding='utf8')
    print(output)
