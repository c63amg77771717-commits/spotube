"""Reuse the strict offline ledger rules against synthetic fixtures only."""
import importlib.util
import json
import pathlib
from fixtures import synthetic_manifests


def verifier(repo):
    path = repo / 'scripts/ios-lyrics-sample/validate_fixed40_live_receipt.py'
    spec = importlib.util.spec_from_file_location('offline_receipt_rules', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def check(repo, receipt_path):
    receipt = json.loads(receipt_path.read_bytes())
    if receipt.get('dataOrigin') != 'entirelySynthetic' or receipt.get('realProviderQueries') is not False:
        raise ValueError('PUBLIC_RECEIPT_SCOPE_BLOCKED')
    return verifier(repo).validate(receipt, synthetic_manifests(), native_mock=True)


def self_test(repo):
    # Synthetic verifier cases never represent provider availability or live rate.
    return verifier(repo).self_test(synthetic_manifests())
