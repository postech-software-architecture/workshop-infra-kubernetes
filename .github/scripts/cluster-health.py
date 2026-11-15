"""Read cluster/dependency health without printing Secret values or raw app logs."""
import json
import re
import subprocess


def call(command):
    p = subprocess.run(command, text=True, capture_output=True, timeout=60)
    return p.returncode, p.stdout


def safe_message(line):
    try:
        value = json.loads(line)
        if value.get('s') not in ('W', 'E', 'F') and not re.search(
                r'ERROR|WARN|Exception|Started |APPLICATION FAILED', line):
            return None
        selected = {k: value[k] for k in ('@timestamp', 'log.level', 'log.logger', 'message',
                                         'error.type', 'error.message', 's', 'c', 'msg', 'attr') if k in value}
        text = json.dumps(selected)
    except ValueError:
        if not re.search(r'ERROR|WARN|Exception|Caused by:|Started |APPLICATION FAILED', line):
            return None
        text = line
    text = re.sub(r'(mongodb(?:\+srv)?://)[^@\s"\\]+@', r'\1[redacted]@', text)
    if re.search(r'secret|password|token|authorization|credential', text, re.I):
        return None
    return re.sub(r'\b(?:AKIA|ASIA)[A-Z0-9]{16}\b|[A-Za-z0-9+/=_-]{80,}', '[redacted]', text)[:2400]


def main():
    code, raw = call(['aws', 'rds', 'describe-db-instances', '--db-instance-identifier', 'workshop-db',
                      '--query', 'DBInstances[].{id:DBInstanceIdentifier,status:DBInstanceStatus,engine:Engine}', '--output', 'json'])
    print('RDS:', raw.strip() if not code else 'metadata query failed; raw error suppressed', flush=True)
    js = "const c=new Mongo('mongodb://127.0.0.1:27017'); const a=c.getDB('admin'); a.auth('root',process.env.MONGO_INITDB_ROOT_PASSWORD); const h=a.runCommand({hello:1}); const s=a.runCommand({replSetGetStatus:1}); print(JSON.stringify({hello:{ok:h.ok,isWritablePrimary:h.isWritablePrimary,setName:h.setName,hosts:h.hosts,me:h.me},status:{ok:s.ok,code:s.code,codeName:s.codeName,myState:s.myState,members:(s.members||[]).map(m=>({name:m.name,state:m.stateStr,health:m.health,lastHeartbeatMessage:m.lastHeartbeatMessage}))}}));"
    code, raw = call(['kubectl', '-n', 'workshop', 'exec', 'mongo-0', '--',
                      'mongosh', '--nodb', '--quiet', '--eval', js])
    # Consume only the explicit JSON summary, never mongosh banners/raw errors.
    mongo = next((line for line in raw.splitlines() if line.startswith('{"hello":')), None)
    print('Mongo replica status:', mongo or 'query failed; raw output suppressed', flush=True)
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
                message = safe_message(line)
                if message:
                    errors.append(message)
            print(json.dumps({'pod': name, 'previous': previous,
                              'signals': {s: output.lower().count(s.lower()) for s in signals},
                              'sanitized_messages': errors[-12:]}), flush=True)


if __name__ == '__main__':
    main()
