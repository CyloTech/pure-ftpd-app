#!/usr/bin/env python3
"""Fail closed unless the authenticated registry confirms this new tag is absent."""
import subprocess
import sys

EXPECTED = 'repo.cylo.net/pure-ftpd:1.0.52-5'
# The image catalogue version 1.0.52-4 runs. The upgrade test starts from it.
CURRENT = 'repo.cylo.net/pure-ftpd@sha256:ce0de8f906331e53ba574306dd3be6b8a3779b1164c5085236debd698a6d060c'


def require_absent(image):
    if image != EXPECTED:
        raise RuntimeError('Unexpected image reference')
    known = subprocess.run(['docker', 'manifest', 'inspect', CURRENT], capture_output=True, text=True, timeout=90)
    if known.returncode:
        raise RuntimeError('Authenticated registry baseline read failed; state is indeterminate')
    result = subprocess.run(['docker', 'manifest', 'inspect', image], capture_output=True, text=True, timeout=90)
    if result.returncode == 0:
        raise RuntimeError('Release tag exists; refusing replacement')
    if result.stderr.strip() != 'no such manifest: ' + image:
        raise RuntimeError('Registry response is indeterminate; refusing publication')
    print('PASS registry: baseline readable and exact release tag definitively absent', flush=True)


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('Usage: registry-check.py IMAGE')
    require_absent(sys.argv[1])
