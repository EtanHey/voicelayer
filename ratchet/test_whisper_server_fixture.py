"""Real loopback fixture regression: name-service stalls cannot block warmup."""
import importlib.util
import json
from pathlib import Path
import socket
import threading
import unittest
from http.server import HTTPServer
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.request import urlopen

spec = importlib.util.spec_from_file_location("server_fixture", Path(__file__).with_name("fixture-whisper-server.py"))
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


class HealthFixtureTests(unittest.TestCase):
    def test_health_serves_without_any_hostname_lookup(self):
        with patch.object(socket, "getfqdn", side_effect=RuntimeError("name service unavailable")) as lookup:
            # The original HTTPServer cannot complete startup under this condition.
            with self.assertRaisesRegex(RuntimeError, "name service unavailable"):
                HTTPServer(("127.0.0.1", 0), fixture.Health)
            lookup.reset_mock()
            with fixture.HealthServer(("127.0.0.1", 0), fixture.Health) as server:
                worker = threading.Thread(target=server.serve_forever)
                worker.start()
                try:
                    address = "http://127.0.0.1:" + str(server.server_port)
                    with urlopen(address + "/health", timeout=2) as response:
                        self.assertEqual(response.status, 200)
                        self.assertEqual(json.load(response), {"status": "ok"})
                    with self.assertRaises(HTTPError) as error:
                        urlopen(address + "/inference", timeout=2)
                    self.assertEqual(error.exception.code, 404)
                    error.exception.close()
                    lookup.assert_not_called()
                finally:
                    server.shutdown()
                    worker.join(2)
                    self.assertFalse(worker.is_alive())


if __name__ == "__main__":
    unittest.main()
