import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

import native_run


class OutageCoordination(unittest.TestCase):
    def test_applies_both_blackholes_and_restores_only_after_queue_and_timer(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            events = []

            def configure(name, rate, rtt, loss, seed, jitter=0):
                events.append((name, rate, rtt, loss, seed, jitter))
                return f'{name}: {loss}%'

            def await_marker(path, process, timeout):
                events.append(path.name)
                if path.name == 'offline-queued':
                    self.assertTrue((root / 'outage-active').exists())
                if path.name == 'restore-timer-ready':
                    self.assertTrue((root / 'restore-starting').exists())

            with (
                patch.object(native_run, 'configure', side_effect=configure),
                patch.object(native_run, 'await_marker', side_effect=await_marker),
                patch.object(native_run.time, 'monotonic', side_effect=[10, 13, 70.05, 70.5]),
                patch.object(native_run.time, 'sleep', side_effect=lambda duration: events.append(duration)),
            ):
                def check_server():
                    events.append('check-server')
                    return [['device', str(i)] for i in range(6)]

                result = native_run.simulate_outage(root, Mock(), {'netem-a': '', 'netem-b': ''}, 7, check_server)

            self.assertEqual(events, [
                'baseline-ready',
                ('netem-a', 100, 0, 100, 7, 0),
                ('netem-b', 100, 0, 100, 107, 0),
                'offline-queued',
                57,
                'check-server',
                'restore-timer-ready',
                ('netem-a', 100, 600, 1, 7, 0),
                ('netem-b', 100, 600, 1, 107, 0),
            ])
            self.assertEqual(result['server_rows_before_restore'], 6)
            self.assertGreaterEqual(result['minimum_blackout_seconds'], 60)
            self.assertEqual(result['blocked_qdiscs'], {'netem-a': 'netem-a: 100%', 'netem-b': 'netem-b: 100%'})

    def test_stops_waiting_when_child_has_exited(self):
        with tempfile.TemporaryDirectory() as tmp:
            process = Mock()
            process.poll.return_value = 1
            with self.assertRaisesRegex(RuntimeError, 'Dart exited before marker'):
                native_run.await_marker(Path(tmp) / 'marker', process, 10)


if __name__ == '__main__':
    unittest.main()
