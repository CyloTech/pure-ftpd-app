#!/usr/bin/env python3
"""Tests for a built Pure-FTPd image, run on a Linux Docker host.

Usage: image-tests.py IMAGE BASELINE_IMAGE

The server runs on its own Docker network and the checks connect to it from
the host with ftplib, over plain FTP and explicit TLS:
  - FEAT advertises EPSV and EPSV is accepted (n8n's FTP client uses EPSV
    whenever FEAT lists it; the old -b flag answered "500 Unknown command");
  - uploads and downloads work over both PASV and EPSV;
  - symlinks to folders and files are listed as folders and files;
  - a failed login and a successful login both reach `docker logs`, and
    neither password does;
  - `docker stop` with a logged-in session finishes well inside Docker's
    timeout, and the server comes back after it with logging still working;
  - BASELINE_IMAGE (the current release) re-created as IMAGE on the same
    passwd volume, as an Appbox update does, keeps the user and its login.
"""
import ftplib
import io
import os
import secrets
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import time

image, baseline = sys.argv[1], sys.argv[2]
suffix = secrets.token_hex(4)
net = f'pureftpd-test-{suffix}'
user = 'gateuser'
password = secrets.token_hex(16)
containers, volumes = [], []
failures = []


def docker(*args, check=True):
    return subprocess.run(['docker', *args], capture_output=True, text=True, timeout=300, check=check)


def ok(name, cond, detail=''):
    print(('PASS ' if cond else 'FAIL ') + name + (f' ({detail})' if detail and not cond else ''), flush=True)
    if not cond:
        failures.append(name)


def create_network():
    for third in range(240, 256):
        if docker('network', 'create', '--subnet', f'172.31.{third}.0/24', net, check=False).returncode == 0:
            return f'172.31.{third}.10'
    raise RuntimeError('could not create a test network')


def volume(kind):
    name = f'pureftpd-test-{kind}-{suffix}'
    docker('volume', 'create', name)
    volumes.append(name)
    return name


def wait_ready(name, ip):
    deadline = time.time() + 60
    while time.time() < deadline:
        try:
            with socket.create_connection((ip, 21), 2) as s:
                s.settimeout(3)
                if s.recv(4).startswith(b'220'):
                    return True
        except OSError:
            pass
        time.sleep(0.5)
    logs = docker('logs', '--tail', '20', name, check=False)
    lines = (logs.stdout + logs.stderr).splitlines()
    print('\n'.join(l for l in lines if 'assword' not in l and password not in l), flush=True)
    return False


def start(img, name, home, pw, ip, work):
    docker('run', '-d', '--name', name, '--network', net, '--ip', ip,
           '--env-file', os.path.join(work, 'env'),
           '-e', f'PUBLICHOST={ip}', '-e', 'FIRST_PORT=30000', '-e', 'LAST_PORT=30009',
           '-e', 'PURE_DBFILE=/etc/pure-ftpd/pureftpd.pdb',
           '-e', 'PURE_PASSWDFILE=/etc/pure-ftpd/passwd/pureftpd.passwd',
           '-v', f'{home}:/home/ftpusers/default', '-v', f'{pw}:/etc/pure-ftpd/passwd',
           '-v', f'{work}/key.pem:/ssl/key.pem:ro', '-v', f'{work}/cert.pem:/ssl/cert.pem:ro',
           img)
    containers.append(name)
    return wait_ready(name, ip)


def connect(ip, tls):
    if tls:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        f = ftplib.FTP_TLS(context=ctx, timeout=15)
    else:
        f = ftplib.FTP(timeout=15)
    f.connect(ip, 21)
    f.login(user, password)
    if tls:
        f.prot_p()
    return f


def round_trip(ip, tls, epsv):
    f = connect(ip, tls)
    if epsv:
        f.af = socket.AF_INET6  # ftplib then sends EPSV and connects to the control peer
    data = secrets.token_bytes(65536)
    name = f'gate-{secrets.token_hex(4)}.bin'
    f.storbinary(f'STOR {name}', io.BytesIO(data))
    out = io.BytesIO()
    f.retrbinary(f'RETR {name}', out.write)
    f.delete(name)
    f.quit()
    return out.getvalue() == data


def check(label, ip, tls):
    mode = 'tls' if tls else 'plain'
    try:
        f = connect(ip, tls)
        ok(f'{label} {mode}: FEAT advertises EPSV', ' EPSV' in f.sendcmd('FEAT'))
        try:
            reply = f.sendcmd('EPSV')
        except ftplib.Error as e:
            reply = str(e)
        ok(f'{label} {mode}: EPSV accepted', reply.startswith('229'), reply)
        f.close()
        ok(f'{label} {mode}: upload/download over PASV', round_trip(ip, tls, False))
        ok(f'{label} {mode}: upload/download over EPSV', round_trip(ip, tls, True))
        f = connect(ip, tls)
        f.af = socket.AF_INET6
        facts = {n: d.get('type') for n, d in f.mlsd('/', facts=['type'])}
        ok(f'{label} {mode}: MLSD over EPSV lists symlinks as their targets',
           facts.get('linkdir') == 'dir' and facts.get('linkfile') == 'file', str(facts))
        lines = []
        f.retrlines('LIST /', lines.append)
        modes = {l.split()[-1]: l[0] for l in lines if '->' not in l}
        ok(f'{label} {mode}: LIST lists symlinks as their targets',
           modes.get('linkdir') == 'd' and modes.get('linkfile') == '-', str(modes))
        f.quit()
    except Exception as e:  # a client error is a test failure, not a crash of the gate
        ok(f'{label} {mode}: client session', False, f'{type(e).__name__}: {e}')


def container_logs(name, since=None):
    args = ['logs'] + (['--since', since] if since else []) + [name]
    out = docker(*args, check=False)
    return out.stdout + out.stderr


def log_check(label, name, ip):
    since = f'{time.time() - 1:.3f}'
    bad = secrets.token_hex(16)
    try:
        f = ftplib.FTP(timeout=15)
        f.connect(ip, 21)
        f.login(user, bad)
        f.quit()
        refused = False
    except ftplib.error_perm:
        refused = True
    ok(f'{label}: wrong password refused', refused)
    try:
        connect(ip, False).quit()
    except Exception as e:
        ok(f'{label}: login', False, f'{type(e).__name__}: {e}')
    failed, logged_in = f'Authentication failed for user [{user}]', f'{user} is now logged in'
    deadline = time.time() + 10
    while True:
        text = container_logs(name, since)
        if (failed in text and logged_in in text) or time.time() > deadline:
            break
        time.sleep(0.5)
    ok(f'{label}: failed login in docker logs', failed in text)
    ok(f'{label}: login in docker logs', logged_in in text)
    full = container_logs(name)
    ok(f'{label}: no debug lines in docker logs', '[DEBUG]' not in full)
    ok(f'{label}: no password in docker logs', password not in full and bad not in full)


def timed_stop(label, name, ip):
    try:
        session = connect(ip, False)
    except Exception as e:
        ok(f'{label}: login before stop', False, f'{type(e).__name__}: {e}')
        return
    began = time.time()
    docker('stop', '-t', '30', name)
    took = time.time() - began
    session.close()
    ok(f'{label}: docker stop with a logged-in session took under 10s', took < 10, f'{took:.1f}s')


def fixture(home):
    docker('run', '--rm', '--entrypoint', 'sh', '-v', f'{home}:/h', image, '-c',
           'mkdir -p /h/realdir && echo hello > /h/file.txt && echo inner > /h/realdir/inner.txt'
           ' && ln -s realdir /h/linkdir && ln -s file.txt /h/linkfile && chown -R 1000:1000 /h')


work = tempfile.mkdtemp(prefix='pureftpd-gate-')
try:
    env_path = os.path.join(work, 'env')
    with open(os.open(env_path, os.O_WRONLY | os.O_CREAT, 0o600), 'w') as env:
        env.write(f'FTP_USER={user}\nFTP_PASSWORD={password}\n')
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                    '-subj', '/CN=localhost', '-keyout', f'{work}/key.pem', '-out', f'{work}/cert.pem'],
                   capture_output=True, check=True, timeout=60)
    os.chmod(f'{work}/key.pem', 0o644)
    ip = create_network()
    docker('pull', '-q', baseline)

    # Fresh install of the new image, then a restart.
    home, pw = volume('home'), volume('pw')
    fixture(home)
    name = f'pureftpd-test-new-{suffix}'
    ok('fresh: server starts', start(image, name, home, pw, ip, work))
    check('fresh', ip, tls=False)
    check('fresh', ip, tls=True)
    log_check('fresh', name, ip)
    timed_stop('stop', name, ip)
    docker('start', name)
    ok('restart: server starts', wait_ready(name, ip))
    check('restart', ip, tls=False)
    log_check('restart', name, ip)
    docker('rm', '-f', name)

    # Update from the current release: same volumes, new container.
    home, pw = volume('uhome'), volume('upw')
    fixture(home)
    name = f'pureftpd-test-old-{suffix}'
    ok('baseline: server starts', start(baseline, name, home, pw, ip, work))
    try:
        f = connect(ip, False)
        f.nlst('/')
        f.quit()
        ok('baseline: login and PASV listing', True)
    except Exception as e:
        ok('baseline: login and PASV listing', False, f'{type(e).__name__}: {e}')
    docker('rm', '-f', name)
    name = f'pureftpd-test-upd-{suffix}'
    ok('update: server starts on the baseline volumes', start(image, name, home, pw, ip, work))
    check('update', ip, tls=False)
    log_check('update', name, ip)
except Exception as e:
    ok('test harness', False, f'{type(e).__name__}: {e}')
finally:
    for c in containers:
        docker('rm', '-f', c, check=False)
    for v in volumes:
        docker('volume', 'rm', '-f', v, check=False)
    docker('network', 'rm', net, check=False)
    shutil.rmtree(work, ignore_errors=True)

if failures:
    raise SystemExit(f'FAIL image tests: {len(failures)} failed')
print('PASS image tests', flush=True)
