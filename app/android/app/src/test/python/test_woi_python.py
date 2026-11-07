import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

source = Path(__file__).resolve().parents[2] / "main/python/woi_python.py"
spec = importlib.util.spec_from_file_location("woi_python", source)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PythonExecutionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)

    def run_code(self, code, limit=8000):
        return json.loads(module.run(code, self.temp.name, limit))

    def test_decimal_calculation(self):
        result = self.run_code("from decimal import Decimal\nprint(Decimal('0.1') + Decimal('0.2'))")
        self.assertEqual(result["stdout"], "0.3\n")
        self.assertEqual(result["exit_code"], 0)

    def test_exception_returns_stderr(self):
        result = self.run_code("print('before')\nraise ValueError('example')")
        self.assertEqual(result["stdout"], "before\n")
        self.assertIn("ValueError: example", result["stderr"])
        self.assertEqual(result["exit_code"], 1)

    def test_output_is_bounded_and_preserves_head_tail(self):
        result = self.run_code("print('HEAD' + 'x' * 100000 + 'TAIL')", 512)
        self.assertTrue(result["truncated"])
        self.assertLess(len(result["stdout"]), 600)
        self.assertTrue(result["stdout"].startswith("HEAD"))
        self.assertTrue(result["stdout"].endswith("TAIL\n"))

    def test_write_returns_actual_length_across_partial_head(self):
        out = module.CappedText(256)
        self.assertEqual(out.write("x" * 190), 190)
        self.assertEqual(out.write("abc"), 3)
        self.assertEqual(out.write("q" * 300), 300)
        self.assertTrue(out.truncated)

    def test_cwd_and_streams_are_restored(self):
        before = os.getcwd(), sys.stdin, sys.stdout, sys.stderr
        result = self.run_code("import os\nprint(os.getcwd())")
        self.assertEqual(result["stdout"].strip(), self.temp.name)
        self.assertEqual((os.getcwd(), sys.stdin, sys.stdout, sys.stderr), before)

    def test_calls_have_independent_namespaces(self):
        self.run_code("secret_value = 7")
        result = self.run_code("print('secret_value' in globals())")
        self.assertEqual(result["stdout"], "False\n")

    def test_system_exit_is_a_result(self):
        result = self.run_code("raise SystemExit(7)")
        self.assertEqual(result["exit_code"], 7)
        self.assertEqual(self.run_code("print(6 * 7)")["stdout"], "42\n")

    def test_boolean_system_exit_returns_numeric_code(self):
        for value, expected in [("False", 0), ("True", 1)]:
            result = self.run_code("import sys\nsys.exit(" + value + ")")
            self.assertIs(type(result["exit_code"]), int)
            self.assertEqual(result["exit_code"], expected)

    def test_binary_and_native_descriptor_output_is_returned(self):
        result = self.run_code("import os, sys\n"
                               "sys.stdout.buffer.write(b'binary-out\\n')\n"
                               "os.write(1, b'native-out\\n')\n"
                               "sys.stderr.buffer.write(b'binary-err\\n')\n"
                               "os.write(2, b'native-err\\n')")
        self.assertEqual(result["stdout"], "binary-out\nnative-out\n")
        self.assertEqual(result["stderr"], "binary-err\nnative-err\n")
        self.assertEqual(result["exit_code"], 0)

    def test_split_utf8_and_invalid_bytes_are_decoded(self):
        result = self.run_code("import os\nos.write(1, b'\\xe2')\n"
                               "os.write(1, b'\\x82\\xac\\xff')")
        self.assertEqual(result["stdout"], "€�")

    def test_subprocess_stdout_and_stderr_are_returned(self):
        result = self.run_code("import subprocess, sys\n"
                               "subprocess.run([sys.executable, '-c', "
                               "\"import os;os.write(1,b'child-out');os.write(2,b'child-err')\"], check=True)")
        self.assertEqual(result["stdout"], "child-out")
        self.assertEqual(result["stderr"], "child-err")

    def test_native_stdio_output_is_flushed(self):
        result = self.run_code("import ctypes\nctypes.CDLL(None).printf(b'native-printf')")
        self.assertEqual(result["stdout"], "native-printf")

    def test_large_native_output_stays_bounded(self):
        result = self.run_code("import os\nos.write(1, b'HEAD' + b'x' * 1000000 + b'TAIL')", 512)
        self.assertTrue(result["truncated"])
        self.assertLess(len(result["stdout"]), 600)
        self.assertTrue(result["stdout"].startswith("HEAD"))
        self.assertTrue(result["stdout"].endswith("TAIL"))

    def test_process_descriptors_are_restored(self):
        before = [(os.fstat(fd).st_dev, os.fstat(fd).st_ino) for fd in (1, 2)]
        self.run_code("import os\nos.close(1)\nos.close(2)")
        self.assertEqual([(os.fstat(fd).st_dev, os.fstat(fd).st_ino) for fd in (1, 2)], before)

    def test_child_inheriting_output_does_not_hold_completion_open(self):
        import signal
        import time
        import warnings
        start = time.monotonic()
        child_pid = None
        pid_file = Path(self.temp.name) / "child.pid"
        try:
            # This fixture intentionally leaves an inheriting child running;
            # the test owns and reaps it rather than relying on Popen.__del__.
            with warnings.catch_warnings():
                warnings.simplefilter("ignore", ResourceWarning)
                result = self.run_code("import subprocess, sys\n"
                                       "child = subprocess.Popen([sys.executable, '-c', 'import time;time.sleep(5)'])\n"
                                       "with open('child.pid', 'w') as record: record.write(str(child.pid))\n"
                                       "print(child.pid)")
            child_pid = int(result["stdout"].strip())
            self.assertLess(time.monotonic() - start, 1.5)
        finally:
            if child_pid is None and pid_file.is_file():
                child_pid = int(pid_file.read_text())
            if child_pid is not None:
                try:
                    os.kill(child_pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                try:
                    os.waitpid(child_pid, 0)
                except ChildProcessError:
                    pass

    def test_stdin_does_not_block(self):
        result = self.run_code("input()")
        self.assertIn("EOFError", result["stderr"])
        self.assertEqual(result["exit_code"], 1)


if __name__ == "__main__":
    unittest.main()
