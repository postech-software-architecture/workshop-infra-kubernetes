"""Run through SSM on an AL2023 EKS node. Never emit credentials or raw config."""
import json
from pathlib import Path
import re
import subprocess
import sys

UNITS = ('nodeadm-boot-hook', 'nodeadm-config', 'nodeadm-run', 'containerd', 'kubelet')
PROPERTIES = ('LoadState', 'ActiveState', 'SubState', 'UnitFileState', 'Result',
              'ExecMainStatus', 'ExecMainStartTimestamp', 'ExecMainExitTimestamp')


def run(args, timeout=30):
    return subprocess.run(args, text=True, capture_output=True, timeout=timeout)


def inspect():
    units = {}
    for unit in UNITS:
        value = run(['systemctl', 'show', unit, *['--property=' + p for p in PROPERTIES]])
        units[unit] = dict(line.split('=', 1) for line in value.stdout.splitlines() if '=' in line)
    journal = run(['journalctl', '-u', 'nodeadm-config', '-u', 'nodeadm-run', '-u', 'kubelet',
                   '--since', '2 days ago', '--no-pager', '-n', '250', '-o', 'cat']).stdout
    patterns = ('voc-cancel-cred', 'AccessDenied', 'ExpiredToken', 'Unauthorized', 'dial tcp',
                'deadline exceeded', 'no space left', 'certificate has expired',
                'failed to load', 'no NodeConfig', 'failed to get', 'credential')
    errors = []
    for line in journal.splitlines():
        if not re.search(r'error|fatal|failed|denied|timeout', line, re.I):
            continue
        if re.search(r'secret|token|password|credential|authorization', line, re.I):
            continue
        line = re.sub(r'\b(?:AKIA|ASIA)[A-Z0-9]{16}\b|[A-Za-z0-9+/=_-]{80,}', '[redacted]', line)
        errors.append(line[:350])
    paths = ('/var/lib/kubelet/kubeconfig', '/etc/kubernetes/kubelet/config.json',
             '/run/eks/nodeadm/config.json', '/etc/eks/nodeadm.d')
    return {'units': units, 'configuration_paths_present': {p: Path(p).exists() for p in paths},
            'journal_signals': {p: journal.lower().count(p.lower()) for p in patterns},
            'sanitized_errors': errors[-8:]}


def main():
    mode = sys.argv[1]
    before = inspect()
    result = {'before': before, 'operation': mode, 'units_started': []}
    if mode == 'resume' and before['units']['kubelet'].get('ActiveState') != 'active':
        # Use the AMI's own ordered bootstrap units, not an ad hoc kubelet enable.
        for name in ('nodeadm-config', 'nodeadm-run'):
            if before['units'][name].get('LoadState') != 'loaded':
                raise ValueError('Expected AL2023 bootstrap unit missing; no recovery attempted')
        run(['systemctl', 'reset-failed', 'nodeadm-config', 'nodeadm-run'])
        for name in ('nodeadm-config', 'nodeadm-run'):
            command = run(['systemctl', 'start', name], timeout=240)
            result['units_started'].append({'unit': name, 'exit_code': command.returncode})
            if command.returncode:
                break
    result['after'] = inspect()
    print(json.dumps(result))
    return 0 if mode == 'inspect' or result['after']['units']['kubelet'].get('ActiveState') == 'active' else 1


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as error:
        print(json.dumps({'error_class': type(error).__name__, 'private_values_suppressed': True}))
        sys.exit(1)
