#!/usr/bin/env python3
"""Disposable home-server-only recovery witness. Never restarts/reboots or touches app data.

prepare -> separately authorized service interruption/reboot -> check-service/check-reboot
Default status is read-only. Failed checks retain the namespace and state for diagnosis.
"""
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import time

CONFIG = Path('/home/steve/.kube/driftplain-home.yaml')
STATE = Path('/home/steve/home-server-setup/recovery-witness.json')
PURPOSE = 'hm2-recovery'
K = ['/usr/local/bin/k3s', 'kubectl', '--kubeconfig', str(CONFIG),
     '--context', 'driftplain-home', '--request-timeout=20s']
os.environ['K3S_CONFIG_FILE'] = '/dev/null'


def run(args, data=None):
    return subprocess.check_output(args, input=data, text=True, timeout=240).strip()


def kub(*args):
    return run(K + list(args))


def obj(kind, name, namespace=None):
    scope = ['-n', namespace] if namespace else []
    return json.loads(kub(*scope, 'get', kind, name, '-o', 'json'))


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def boot():
    return Path('/proc/sys/kernel/random/boot_id').read_text().strip()


def invocation():
    return run(['systemctl', 'show', 'k3s', '-p', 'InvocationID', '--value'])


def preflight():
    require(socket.gethostname() == 'home-server', 'Wrong host; home-server required')
    require(CONFIG.stat().st_mode & 0o777 == 0o600, 'Unsafe kubeconfig permissions')
    require(CONFIG.stat().st_uid == os.getuid(), 'Run as kubeconfig owner (steve)')
    require(run(['findmnt', '-no', 'UUID', '/']) ==
            '9ce972e8-f060-45fc-97fe-296664de6a7c', 'Unexpected root filesystem')
    require(kub('config', 'view', '--minify', '-o',
                'jsonpath={.clusters[0].cluster.server}') == 'https://127.0.0.1:6443',
            'Refusing non-loopback API')
    nodes = json.loads(kub('get', 'nodes', '-o', 'json'))['items']
    require(len(nodes) == 1 and nodes[0]['metadata']['name'] == 'driftplain-home',
            'Unexpected cluster identity')
    return nodes[0]


def save(state, exclusive=False):
    # Evidence contains only disposable IDs/hashes; no cluster credentials or user data.
    STATE.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if exclusive:
        with STATE.open('x') as handle:
            json.dump(state, handle, indent=2)
    else:
        temporary = STATE.with_suffix('.tmp')
        with temporary.open('x') as handle:
            json.dump(state, handle, indent=2)
        temporary.replace(STATE)


def owned(state):
    ns = state['namespace']
    require(ns.startswith('home-server-recovery-'), 'Unexpected witness namespace')
    metadata = obj('namespace', ns)['metadata']
    require(metadata['uid'] == state['namespace_uid'] and
            metadata.get('labels', {}).get('driftplain.dev/purpose') == PURPOSE,
            'Namespace ownership changed; refusing operation')
    return ns


def prepare(node):
    require(not STATE.exists(), f'Existing witness: {STATE}; inspect before cleanup')
    namespaces = json.loads(kub('get', 'namespaces', '-o', 'json'))['items']
    require({n['metadata']['name'] for n in namespaces} <=
            {'default', 'kube-system', 'kube-public', 'kube-node-lease'},
            'This drill is for the empty HM2 cluster; unexpected namespaces exist')
    ns = 'home-server-recovery-' + secrets.token_hex(6)
    namespace = {'apiVersion': 'v1', 'kind': 'Namespace', 'metadata': {
        'name': ns, 'labels': {'driftplain.dev/purpose': PURPOSE,
                             'pod-security.kubernetes.io/enforce': 'restricted',
                             'pod-security.kubernetes.io/enforce-version': 'v1.36'}}}
    run(K + ['create', '-f', '-'], json.dumps(namespace))
    state = {'namespace': ns, 'namespace_uid': obj('namespace', ns)['metadata']['uid'],
             'node_uid': node['metadata']['uid'], 'boot_id': boot(),
             'invocation_id': invocation(), 'prepared_at': now(), 'phase': 'preparing'}
    save(state, exclusive=True)
    pvc = {'apiVersion': 'v1', 'kind': 'PersistentVolumeClaim', 'metadata': {'name': 'proof'},
           'spec': {'storageClassName': 'local-path', 'accessModes': ['ReadWriteOnce'],
                    'resources': {'requests': {'storage': '128Mi'}}}}
    deployment = {'apiVersion': 'apps/v1', 'kind': 'Deployment', 'metadata': {'name': 'proof'},
                  'spec': {'replicas': 1, 'selector': {'matchLabels': {'app': 'proof'}},
                           'template': {'metadata': {'labels': {'app': 'proof'}}, 'spec': {
                               'automountServiceAccountToken': False,
                               'securityContext': {'runAsNonRoot': True, 'runAsUser': 1000,
                                                   'runAsGroup': 1000, 'fsGroup': 1000,
                                                   'seccompProfile': {'type': 'RuntimeDefault'}},
                               'containers': [{
                                   'name': 'proof',
                                   'image': 'docker.io/library/busybox:1.37.0@sha256:'
                                            '7a3ebe5bfd1a4a19797d20b0c0bb39d44393e9a03fd852c0865b0f540d868df0',
                                   # Startup never writes/recreates the witness.
                                   'command': ['httpd', '-f', '-p', '8080', '-h', '/data'],
                                   'securityContext': {'allowPrivilegeEscalation': False,
                                                       'readOnlyRootFilesystem': True,
                                                       'capabilities': {'drop': ['ALL']}},
                                   'resources': {'requests': {'cpu': '10m', 'memory': '16Mi'},
                                                 'limits': {'cpu': '100m', 'memory': '64Mi'}},
                                   'readinessProbe': {'tcpSocket': {'port': 8080}, 'periodSeconds': 2},
                                   'volumeMounts': [{'name': 'data', 'mountPath': '/data'}]}],
                               'volumes': [{'name': 'data', 'persistentVolumeClaim': {'claimName': 'proof'}}]}}}}
    service = {'apiVersion': 'v1', 'kind': 'Service', 'metadata': {'name': 'proof'},
               'spec': {'selector': {'app': 'proof'}, 'ports': [{'port': 8080}]}}
    run(K + ['-n', ns, 'create', '-f', '-'], json.dumps(
        {'apiVersion': 'v1', 'kind': 'List', 'items': [pvc, deployment, service]}))
    kub('-n', ns, 'rollout', 'status', 'deployment/proof', '--timeout=180s')
    token = secrets.token_hex(32)
    kub('-n', ns, 'exec', 'deployment/proof', '--', 'sh', '-ec',
        'test ! -e /data/index.html; printf %s "$1" > /data/index.html; sync', 'sh', token)
    claim = obj('pvc', 'proof', ns)
    volume = obj('pv', claim['spec']['volumeName'])
    state.update(phase='prepared', pvc_uid=claim['metadata']['uid'],
                 pv_name=volume['metadata']['name'], pv_uid=volume['metadata']['uid'],
                 sha256=hashlib.sha256(token.encode()).hexdigest())
    save(state)
    print(json.dumps(state, indent=2))


def check(state, node, mode):
    started = time.monotonic()
    ns = owned(state)
    require(state['phase'] == 'prepared', 'Preparation incomplete; inspect retained witness')
    require(node['metadata']['uid'] == state['node_uid'], 'Node was replaced')
    if mode == 'check-service':
        require(boot() == state['boot_id'], 'Host rebooted; use check-reboot')
        require(invocation() != state['invocation_id'], 'K3s has not restarted since preparation')
    elif mode == 'check-reboot':
        require(boot() != state['boot_id'], 'Host has not rebooted since preparation')
    require(run(['systemctl', 'is-active', 'k3s']) == 'active', 'K3s not active')
    require(run(['systemctl', 'is-enabled', 'k3s']) == 'enabled', 'K3s not boot-enabled')
    kub('wait', 'node/driftplain-home', '--for=condition=Ready', '--timeout=180s')
    for name in ('coredns', 'local-path-provisioner', 'metrics-server'):
        kub('-n', 'kube-system', 'rollout', 'status', f'deployment/{name}', '--timeout=180s')
    kub('-n', ns, 'rollout', 'status', 'deployment/proof', '--timeout=180s')
    claim = obj('pvc', 'proof', ns)
    require(claim['metadata']['uid'] == state['pvc_uid'] and
            claim['spec']['volumeName'] == state['pv_name'], 'PVC changed')
    require(obj('pv', state['pv_name'])['metadata']['uid'] == state['pv_uid'], 'PV changed')
    content = kub('-n', ns, 'exec', 'deployment/proof', '--', 'wget', '-T', '15', '-qO-',
                  'http://proof:8080/index.html')
    require(hashlib.sha256(content.encode()).hexdigest() == state['sha256'], 'Witness content changed')
    for target in ('kubernetes.default.svc.cluster.local', 'github.com'):
        kub('-n', ns, 'exec', 'deployment/proof', '--', 'nslookup', target)
    kub('-n', ns, 'exec', 'deployment/proof', '--', 'wget', '-T', '15', '-q', '-O', '/dev/null',
        'http://example.com')
    result = {'check': mode, 'passed_at': now(), 'boot_id': boot(), 'invocation_id': invocation(),
              'verification_seconds': round(time.monotonic() - started, 2)}
    if mode != 'status':
        state[mode] = result
        save(state)
    print(json.dumps(result, indent=2))


def main():
    os.umask(0o077)
    mode = sys.argv[1] if len(sys.argv) == 2 else 'status'
    require(len(sys.argv) <= 2 and mode in
            ('prepare', 'status', 'check-service', 'check-reboot', 'cleanup'),
            'Usage: recovery-check.py [prepare|status|check-service|check-reboot|cleanup]')
    node = preflight()
    if mode == 'prepare':
        prepare(node)
        return
    state = json.loads(STATE.read_text())
    if mode == 'cleanup':
        ns = owned(state)
        kub('delete', 'namespace', ns, '--wait=true', '--timeout=120s')
        if state.get('pv_name'):
            kub('wait', '--for=delete', 'pv/' + state['pv_name'], '--timeout=120s')
        STATE.rename(STATE.with_name('recovery-witness-' + ns + '.json'))
        print('Removed only owned disposable witness; archived evidence retained.')
    else:
        check(state, node, mode)


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, KeyError, subprocess.SubprocessError) as exc:
        sys.exit(f'FAIL: {exc}; no automatic cleanup/restart/reboot performed')
