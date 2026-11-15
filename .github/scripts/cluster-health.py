"""Read cluster/dependency health without printing Secret values or raw app logs."""
import json
import re
import subprocess


def call(command):
    p = subprocess.run(command, text=True, capture_output=True, timeout=60)
    return p.returncode, p.stdout


def main():
    code, raw = call(['aws', 'rds', 'describe-db-instances', '--db-instance-identifier', 'workshop-db',
                      '--query', 'DBInstances[].{id:DBInstanceIdentifier,status:DBInstanceStatus,engine:Engine}', '--output', 'json'])
    print('RDS:', raw.strip() if not code else 'metadata query failed; raw error suppressed', flush=True)
    for command in (
        ['kubectl', 'get', 'nodes', '-o', 'wide'],
        ['kubectl', '-n', 'workshop', 'get', 'deployments,statefulsets,pods,pvc', '-o', 'wide'],
        ['kubectl', '-n', 'workshop', 'get', 'events', '--field-selector', 'type=Warning', '--sort-by=.lastTimestamp'],
        ['kubectl', 'top', 'nodes'],
        ['kubectl', '-n', 'workshop', 'top', 'pods'],
    ):
        code, output = call(command)
        print(json.dumps({'query': command[1:], 'exit_code': code, 'output': output[-10000:]}), flush=True)
    code, raw = call(['kubectl', '-n', 'workshop', 'get', 'pods', '-o', 'json'])
    if code:
        return
    for pod in json.loads(raw)['items']:
        app = pod['metadata'].get('labels', {}).get('app')
        if app not in ('os-service', 'billing-service', 'execucao-service', 'rabbit', 'mongo'):
            continue
        name = pod['metadata']['name']
        for previous in (False, True):
            command = ['kubectl', '-n', 'workshop', 'logs', name, '--all-containers=true', '--tail=180']
            if previous:
                command.append('--previous')
            code, output = call(command)
            if code:
                continue
            signals = ('Connection refused', 'Connection timed out', 'Hikari', 'Flyway', 'OutOfMemory',
                       'password authentication failed', 'ACCESS_REFUSED', 'Started ', 'MongoSocket',
                       'APPLICATION FAILED TO START', 'UnknownHostException', 'Shutdown')
            errors = []
            for line in output.splitlines():
                if not re.search(r'ERROR|WARN|Exception|Caused by:|Started |APPLICATION FAILED', line):
                    continue
                if re.search(r'secret|password|token|authorization|credential', line, re.I):
                    continue
                errors.append(re.sub(r'\b(?:AKIA|ASIA)[A-Z0-9]{16}\b|[A-Za-z0-9+/=_-]{80,}', '[redacted]', line)[:500])
            print(json.dumps({'pod': name, 'previous': previous,
                              'signals': {s: output.lower().count(s.lower()) for s in signals},
                              'sanitized_messages': errors[-12:]}), flush=True)


if __name__ == '__main__':
    main()
