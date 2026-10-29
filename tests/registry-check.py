#!/usr/bin/env python3
"""Fail closed unless the authenticated registry confirms this new tag is absent."""
import subprocess
import sys

EXPECTED = 'repo.cylo.net/pure-ftpd:1.0.52-3'
# The image catalogue version 1.0.52-2 runs. The upgrade test starts from it.
CURRENT = 'repo.cylo.net/pure-ftpd@sha256:83d2f03a1ba674eb7babc80cde419f55b9d1544feb838b45833f2a01c2f43fc1'


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
