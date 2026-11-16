import base64
from contextlib import redirect_stdout
import importlib.util
import io
import json
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('diagnostics', Path(__file__).with_name('node-ssm.py'))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class DiagnosticsTest(unittest.TestCase):
    def invoke(self, *, state='running', ping='Online', instances=True):
        calls = []
        def aws(*args):
            calls.append(args)
            if args[:2] == ('eks', 'describe-cluster'):
                return {'cluster': {'endpoint': 'https://test.invalid', 'resourcesVpcConfig': {'vpcId': 'vpc-test'}}}
            if args[:2] == ('eks', 'describe-nodegroup'):
                return {'nodegroup': {'status': 'ACTIVE', 'amiType': 'AL2023_x86_64_STANDARD',
                    'scalingConfig': {'desiredSize': 2}, 'resources': {'autoScalingGroups': [{'name': 'asg-test'}]}}}
            if args[:2] == ('autoscaling', 'describe-auto-scaling-groups'):
                return {'AutoScalingGroups': [{'AutoScalingGroupName': 'asg-test', 'DesiredCapacity': 2,
                    'Instances': [{'InstanceId': 'i-test', 'LifecycleState': 'InService'}] if instances else []}]}
            if args[:2] == ('ec2', 'describe-instances'):
                return {'Reservations': [{'Instances': [{'InstanceId': 'i-test', 'VpcId': 'vpc-test',
                    'State': {'Name': state}, 'NeverPrint': 'private-response-sentinel'}]}]}
            if args[:2] == ('ec2', 'describe-instance-attribute'):
                user_data = 'Content-Type: application/node.eks.aws\n\nworkshop-eks https://test.invalid'
                return {'UserData': {'Value': base64.b64encode(user_data.encode()).decode()}}
            if args[:2] == ('ssm', 'describe-instance-information'):
                return {'InstanceInformationList': [{'InstanceId': 'i-test', 'PingStatus': ping}] if ping else []}
            raise AssertionError('Unexpected call, including attempted mutation: ' + str(args[:2]))
        output = io.StringIO()
        with patch.object(runner, 'aws', side_effect=aws), \
                patch.object(runner.sys, 'argv', ['node-ssm.py', '--cluster', 'workshop-eks', '--operation', 'resume']), \
                redirect_stdout(output), self.assertRaises(runner.GuardFailure) as error:
            runner.main()
        self.assertNotIn('private-response-sentinel', output.getvalue())
        self.assertFalse(any(c[:2] == ('ssm', 'send-command') for c in calls))
        return [json.loads(line) for line in output.getvalue().splitlines()], str(error.exception), calls

    def test_empty_asg_reports_capacity_and_stops_before_ec2_or_ssm(self):
        reports, reason, calls = self.invoke(instances=False)
        self.assertEqual(2, reports[-1]['groups'][0]['desired'])
        self.assertEqual([], reports[-1]['groups'][0]['instances'])
        self.assertIn('InService', reason)
        self.assertFalse(any(c[0] in ('ec2', 'ssm') for c in calls))

    def test_stopped_instance_is_reported_without_attempting_restart(self):
        reports, reason, calls = self.invoke(state='stopped')
        self.assertEqual('stopped', reports[-1]['instances'][0]['state'])
        self.assertIn('running', reason)
        self.assertFalse(any(c[0] == 'ssm' for c in calls))

    def test_offline_or_unregistered_ssm_is_reported_without_sending_command(self):
        for ping in ('ConnectionLost', None):
            with self.subTest(ping=ping):
                reports, reason, _ = self.invoke(ping=ping)
                self.assertEqual(ping or 'NotRegistered', reports[-1]['instances'][0]['ping_status'])
                self.assertIn('online in SSM', reason)


if __name__ == '__main__':
    unittest.main()
