"""Bounded output for a single Python tool call in Woi's worker process."""
import codecs
import io
import json
import os
import select
import sys
import threading
import time
import traceback


class CappedText(io.TextIOBase):
    def __init__(self, limit):
        self.limit = max(256, int(limit))
        self.head_limit = self.limit * 3 // 4
        self.tail_limit = self.limit - self.head_limit
        self.head = ""
        self.tail = ""
        self.total = 0

    @property
    def encoding(self):
        return "utf-8"

    def writable(self):
        return True

    def write(self, value):
        if not isinstance(value, str):
            raise TypeError("write() requires str")
        length = len(value)
        self.total += length
        remaining = self.head_limit - len(self.head)
        self.head += value[:max(0, remaining)]
        value = value[max(0, remaining):]
        if value:
            self.tail = (self.tail + value[-self.tail_limit:])[-self.tail_limit:]
        return length

    def flush(self):
        pass

    @property
    def truncated(self):
        return self.total > self.limit

    def getvalue(self):
        if not self.truncated:
            return self.head + self.tail
        dropped = self.total - len(self.head) - len(self.tail)
        return self.head + "\n...[%d characters truncated]...\n" % dropped + self.tail


class FdCapture:
    """Capture the process FDs as well as Python's text/binary stream APIs.

    Used only by one call in a disposable worker. Readers keep bounded text
    while draining all bytes so a noisy child cannot fill a pipe indefinitely.
    A child which inherits an open write handle cannot hold completion open.
    """
    def __init__(self, limit):
        self.out = CappedText(limit)
        self.err = CappedText(limit // 2)
        self.saved = {}
        self.streams = []
        self.readers = []
        self.old_streams = sys.stdin, sys.stdout, sys.stderr
        self.stop_at = None
        self.stderr = None

    def _read(self, fd, target):
        decoder = codecs.getincrementaldecoder("utf-8")("replace")
        try:
            while self.stop_at is None or time.monotonic() < self.stop_at:
                ready, _, _ = select.select([fd], [], [], 0.02)
                if not ready:
                    continue
                data = os.read(fd, 8192)
                if not data:
                    break
                target.write(decoder.decode(data))
            target.write(decoder.decode(b"", final=True))
        except (OSError, ValueError):
            # The worker is being torn down or user code closed its descriptors.
            pass
        finally:
            try:
                os.close(fd)
            except OSError:
                pass

    def __enter__(self):
        try:
            for stream in self.old_streams[1:]:
                try:
                    stream.flush()
                except (OSError, ValueError):
                    pass
            for fd, target in [(1, self.out), (2, self.err)]:
                self.saved[fd] = os.dup(fd)
                read_fd, write_fd = os.pipe()
                try:
                    os.dup2(write_fd, fd)
                except BaseException:
                    os.close(read_fd)
                    raise
                finally:
                    os.close(write_fd)
                reader = threading.Thread(target=self._read, args=(read_fd, target), daemon=True)
                self.readers.append(reader)
                reader.start()
            # FileIO preserves .buffer and .fileno(), including os.write and
            # inherited subprocess descriptors. closefd=False leaves restoration
            # of the process descriptors solely to this context manager.
            stdout = io.TextIOWrapper(io.FileIO(1, "wb", closefd=False), encoding="utf-8",
                                      errors="backslashreplace", write_through=True)
            stderr = io.TextIOWrapper(io.FileIO(2, "wb", closefd=False), encoding="utf-8",
                                      errors="backslashreplace", write_through=True)
            self.streams = [stdout, stderr]
            self.stderr = stderr
            sys.stdin, sys.stdout, sys.stderr = io.StringIO(""), stdout, stderr
            return self
        except BaseException:
            self.__exit__(None, None, None)
            raise

    def __exit__(self, exc_type, exc, tb):
        for stream in self.streams:
            try:
                stream.flush()
            except (OSError, ValueError):
                pass
        # Flush C stdio too when available. os.write and subprocess pipe writes
        # are already unbuffered; this also captures native printf output.
        try:
            import ctypes
            ctypes.CDLL(None).fflush(None)
        except (ImportError, OSError, AttributeError):
            pass
        sys.stdin, sys.stdout, sys.stderr = self.old_streams
        for stream in self.streams:
            try:
                stream.close()
            except (OSError, ValueError):
                pass
        for fd, saved in self.saved.items():
            try:
                os.dup2(saved, fd)
            finally:
                os.close(saved)
        self.saved.clear()
        self.stop_at = time.monotonic() + 0.2
        for reader in self.readers:
            if reader.ident is not None:
                reader.join(timeout=0.5)
        return False


def run(code, cwd, max_output_chars=8000):
    started = time.monotonic()
    old_cwd, old_argv = os.getcwd(), sys.argv
    exit_code = 0
    with FdCapture(max_output_chars) as capture:
        try:
            sys.argv = ["<woi-python>"]
            os.chdir(cwd)
            namespace = {"__name__": "__main__", "__file__": "<woi-python>"}
            exec(compile(code, "<woi-python>", "exec"), namespace, namespace)
        except SystemExit as exc:
            # bool is an int subclass; JSON booleans are not Dart numeric values.
            exit_code = int(exc.code) if isinstance(exc.code, int) else (0 if exc.code is None else 1)
            if exc.code is not None and not isinstance(exc.code, int):
                print(str(exc.code), file=capture.stderr)
        except BaseException:
            exit_code = 1
            traceback.print_exc(file=capture.stderr)
        finally:
            sys.argv = old_argv
            os.chdir(old_cwd)
    return json.dumps({
        "exit_code": exit_code,
        "stdout": capture.out.getvalue(),
        "stderr": capture.err.getvalue(),
        "ms": round((time.monotonic() - started) * 1000),
        "truncated": capture.out.truncated or capture.err.truncated,
    })
