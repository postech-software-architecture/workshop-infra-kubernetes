"""Inspect/resume only the current managed node group's existing AL2023 instances."""
import argparse
import base64
from email import message_from_string
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time


class GuardFailure(ValueError):
    """A fixed diagnostic message safe to display without raw AWS responses."""


def emit_report(stage, **metadata):
    print(json.dumps({'stage': stage, **metadata}), flush=True)


def aws(*args):
    p = subprocess.run(['aws', *args, '--output', 'json'], capture_output=True, text=True, timeout=60)
    if p.returncode:
        code = re.search(r'\((\w+)\) when calling', p.stderr)
        raise RuntimeError('AWS request failed: ' + (code.group(1) if code else 'CommandFailed'))
    return json.loads(p.stdout)


def validate_instances(instances, expected_ids, vpc):
    if {x['InstanceId'] for x in instances} != set(expected_ids) or not 1 <= len(instances) <= 3:
        raise GuardFailure('Unexpected instance scope')
    if any(x['VpcId'] != vpc or x['State']['Name'] != 'running' for x in instances):
        raise GuardFailure('All target instances must be running inside the cluster VPC')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cluster', required=True)
    parser.add_argument('--operation', choices=('inspect', 'resume'), default='inspect')
    args = parser.parse_args()
    cluster = aws('eks', 'describe-cluster', '--name', args.cluster)['cluster']
    group = aws('eks', 'describe-nodegroup', '--cluster-name', args.cluster,
                '--nodegroup-name', 'default')['nodegroup']
    emit_report('nodegroup', cluster=args.cluster, status=group.get('status'),
           ami_type=group.get('amiType'), scaling=group.get('scalingConfig'),
           issues=[{'code': x.get('code'), 'resource_ids': x.get('resourceIds', [])}
                   for x in group.get('health', {}).get('issues', [])])
    if group['status'] != 'ACTIVE' or not group.get('amiType', '').startswith('AL2023'):
        raise GuardFailure('Recovery requires the existing ACTIVE AL2023 managed node group')
    names = [x['name'] for x in group['resources']['autoScalingGroups']]
    groups = aws('autoscaling', 'describe-auto-scaling-groups', '--auto-scaling-group-names', *names)['AutoScalingGroups']
    emit_report('autoscaling', groups=[{
        'name': g['AutoScalingGroupName'], 'desired': g.get('DesiredCapacity'),
        'min': g.get('MinSize'), 'max': g.get('MaxSize'),
        'suspended_processes': [p.get('ProcessName') for p in g.get('SuspendedProcesses', [])],
        'instances': [{'id': x['InstanceId'], 'lifecycle': x.get('LifecycleState'),
                       'health': x.get('HealthStatus')}
                      for x in g.get('Instances', [])]} for g in groups])
    ids = sorted({x['InstanceId'] for g in groups for x in g['Instances'] if x['LifecycleState'] == 'InService'})
    if not 1 <= len(ids) <= 3:
        raise GuardFailure('Expected 1 to 3 InService instances in the managed Auto Scaling group')
    reservations = aws('ec2', 'describe-instances', '--instance-ids', *ids)['Reservations']
    instances = [x for r in reservations for x in r['Instances']]
    emit_report('ec2', instances=[{'id': x['InstanceId'], 'state': x['State']['Name'],
                             'in_cluster_vpc': x['VpcId'] == cluster['resourcesVpcConfig']['vpcId']}
                            for x in instances])
    validate_instances(instances, ids, cluster['resourcesVpcConfig']['vpcId'])
    for instance_id in ids:
        data = aws('ec2', 'describe-instance-attribute', '--instance-id', instance_id,
                   '--attribute', 'userData').get('UserData', {}).get('Value', '')
        text = base64.b64decode(data).decode()
        mime = message_from_string(text)
        parts = [p.get_payload(decode=True).decode() for p in mime.walk()
                 if p.get_content_type() == 'application/node.eks.aws']
        if not any(args.cluster in p and cluster['endpoint'] in p for p in parts):
            raise GuardFailure('Managed NodeConfig does not match the selected cluster')
    online = aws('ssm', 'describe-instance-information', '--filters',
                 json.dumps([{'Key': 'InstanceIds', 'Values': ids}]))['InstanceInformationList']
    emit_report('ssm', instances=[{'id': instance_id, 'ping_status': next(
        (x.get('PingStatus') for x in online if x['InstanceId'] == instance_id), 'NotRegistered')}
        for instance_id in ids])
    if {x['InstanceId'] for x in online if x['PingStatus'] == 'Online'} != set(ids):
        raise GuardFailure('All managed instances must be online in SSM')
    print(json.dumps({'cluster': args.cluster, 'operation': args.operation, 'instances': ids,
                      'managed_nodeconfig_matches': True, 'ssm_online': True}), flush=True)
    remote = Path(__file__).with_name('node-service.py').read_text()
    parameters = {'commands': ['python3 - ' + args.operation + " <<'NODE_SERVICE_PY'\n" + remote + '\nNODE_SERVICE_PY'],
                  'executionTimeout': ['600']}
    with tempfile.TemporaryDirectory() as temporary:
        path = Path(temporary) / 'parameters.json'
        path.write_text(json.dumps(parameters))
        command = aws('ssm', 'send-command', '--document-name', 'AWS-RunShellScript',
                      '--instance-ids', *ids, '--parameters', 'file://' + str(path),
                      '--comment', 'SOAT existing EKS node services ' + args.operation)['Command']['CommandId']
    failed = False
    for instance_id in ids:
        invocation = None
        for _ in range(140):
            try:
                invocation = aws('ssm', 'get-command-invocation', '--command-id', command, '--instance-id', instance_id)
            except RuntimeError as error:
                if 'InvocationDoesNotExist' not in str(error):
                    raise
            if invocation and invocation['Status'] not in ('Pending', 'InProgress', 'Delayed'):
                break
            time.sleep(5)
        if not invocation or invocation['Status'] not in ('Success', 'Failed', 'TimedOut', 'Cancelled'):
            raise RuntimeError('SSM command did not finish inside its bounded execution window')
        raw = invocation['StandardOutputContent'].strip()
        try:
            report = json.loads(raw)
        except ValueError:
            report = {'unparseable_output_suppressed': True}
        print(json.dumps({'instance': instance_id, 'status': invocation['Status'], 'report': report}), flush=True)
        failed |= invocation['Status'] != 'Success'
    return int(failed)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, KeyError, RuntimeError, OSError, subprocess.SubprocessError) as error:
        print('Node maintenance failed: ' + (str(error) if isinstance(error, (RuntimeError, GuardFailure)) else type(error).__name__), file=sys.stderr)
        sys.exit(1)
