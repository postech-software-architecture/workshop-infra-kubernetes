import copy
from contextlib import redirect_stdout
import importlib.util
import io
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


runner = load('runner', 'node-ssm.py')
node = load('node', 'node-service.py')


class NodeServicesTest(unittest.TestCase):
    def test_instances_outside_managed_scope_or_vpc_are_rejected(self):
        instance = {'InstanceId': 'i-current', 'VpcId': 'vpc-current', 'State': {'Name': 'running'}}
        runner.validate_instances([instance], ['i-current'], 'vpc-current')
        for ids, vpc in [(['i-other'], 'vpc-current'), (['i-current'], 'vpc-other')]:
            with self.assertRaises(ValueError):
                runner.validate_instances([instance], ids, vpc)
        instance['State']['Name'] = 'stopped'
        with self.assertRaises(ValueError):
            runner.validate_instances([instance], ['i-current'], 'vpc-current')

    def test_active_kubelet_is_not_reinitialized(self):
        state = {'units': {'kubelet': {'ActiveState': 'active'}}}
        with patch.object(node, 'inspect', return_value=state), patch.object(node, 'run') as run, \
                patch.object(node.sys, 'argv', ['node-service.py', 'resume']), redirect_stdout(io.StringIO()):
            self.assertEqual(0, node.main())
        run.assert_not_called()

    def test_failed_config_start_does_not_launch_run_phase_or_enable_kubelet(self):
        state = {'units': {k: {'ActiveState': 'inactive', 'LoadState': 'loaded'}
                           for k in ('kubelet', 'nodeadm-config', 'nodeadm-run')}}
        with patch.object(node, 'inspect', return_value=state), \
                patch.object(node, 'run', return_value=SimpleNamespace(returncode=1)) as run, \
                patch.object(node.sys, 'argv', ['node-service.py', 'resume']), redirect_stdout(io.StringIO()):
            self.assertEqual(1, node.main())
        self.assertEqual([['systemctl', 'reset-failed', 'nodeadm-config', 'nodeadm-run'],
                          ['systemctl', 'start', 'nodeadm-config']], [x.args[0] for x in run.call_args_list])


if __name__ == '__main__':
    unittest.main()
