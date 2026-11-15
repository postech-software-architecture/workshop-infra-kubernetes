import importlib.util
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('health', Path(__file__).with_name('cluster-health.py'))
health = importlib.util.module_from_spec(spec)
spec.loader.exec_module(health)


class NodeHealthTest(unittest.TestCase):
    def test_extracts_cause_without_jdbc_stack_or_mongo_credentials(self):
        raw = json.dumps({'log.level': 'ERROR', 'error.type': 'MongoTimeoutException',
                          'error.message': 'No primary at mongodb://example-user:example-value@mongo:27017',
                          'error.stack_trace': 'irrelevant huge stack'})
        message = health.safe_message(raw)
        self.assertIn('No primary', message)
        self.assertNotIn('example-value', message)
        self.assertNotIn('huge stack', message)

    def test_mongo_warning_is_visible_but_secret_lines_are_suppressed(self):
        self.assertIn('REPL', health.safe_message(json.dumps({'s': 'W', 'c': 'REPL', 'msg': 'No primary'})))
        self.assertIsNone(health.safe_message('ERROR password=example-value'))


if __name__ == '__main__':
    unittest.main()
