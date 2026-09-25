"""Exercises the real Win32 helper with disposable app bundles, never user data.

Build with -DACTIONNOTES_UPDATER_TESTS=ON, then pass the Release directory.
"""
import ctypes
from ctypes import wintypes
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

BIN = pathlib.Path(sys.argv.pop(1)).resolve()
KERNEL = ctypes.WinDLL('kernel32', use_last_error=True)
KERNEL.CreateFileW.restype = wintypes.HANDLE
KERNEL.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                             wintypes.LPVOID, wintypes.DWORD, wintypes.DWORD,
                             wintypes.HANDLE]
KERNEL.CloseHandle.argtypes = [wintypes.HANDLE]
KERNEL.OpenProcess.restype = wintypes.HANDLE
KERNEL.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
KERNEL.TerminateProcess.argtypes = [wintypes.HANDLE, wintypes.UINT]
KERNEL.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]


def wait_for(path, seconds=15):
    until = time.monotonic() + seconds
    while not path.exists():
        if time.monotonic() > until:
            raise AssertionError(f'Timed out waiting for {path}')
        time.sleep(.05)


class UpdaterTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='an-update-')
        # Spaces, non-ASCII and an apostrophe exercise native argument handling.
        self.root = pathlib.Path(self.temp.name) / "Graham's app ü"
        self.root.mkdir()
        self.stage = self.root / '.actionnotes-update-test'
        self.payload = self.stage / 'payload'
        self.payload.mkdir(parents=True)
        for folder, label in [(self.root, b'old'), (self.payload, b'new')]:
            shutil.copy2(BIN / 'updater_test_app.exe', folder / 'actionnotes.exe')
            shutil.copy2(BIN / 'actionnotes_updater.exe', folder / 'actionnotes_updater.exe')
            (folder / 'flutter_windows.dll').write_bytes(label)
            data = folder / 'data'
            (data / 'flutter_assets').mkdir(parents=True)
            (data / 'app.so').write_bytes(label)
            (data / 'icudtl.dat').write_bytes(label)
            (data / 'flutter_assets' / 'AssetManifest.bin').write_bytes(label)
        (self.root / 'my-notes.md').write_text('keep my notes')
        shutil.copy2(BIN / 'actionnotes_updater.exe', self.stage / 'updater.exe')
        self.parent = subprocess.Popen([str(self.root / 'actionnotes.exe'), '--hold'])
        self.helper = None

    def tearDown(self):
        if self.parent.poll() is None:
            self.parent.terminate()
            self.parent.wait(timeout=10)
        if self.helper and self.helper.poll() is None:
            self.helper.terminate()
            self.helper.wait(timeout=10)
        pid = self.root / 'launched.pid'
        if pid.exists():
            handle = KERNEL.OpenProcess(0x100001, False, int(pid.read_text()))
            if handle:
                KERNEL.TerminateProcess(handle, 0)
                KERNEL.WaitForSingleObject(handle, 10000)
                KERNEL.CloseHandle(handle)
        self.temp.cleanup()

    def start(self, wait_ready=True):
        self.helper = subprocess.Popen([str(self.stage / 'updater.exe'),
            str(self.root), str(self.stage), str(self.parent.pid)])
        if wait_ready:
            wait_for(self.stage / 'ready')
            # Must not touch the running bundle before the parent exits.
            self.assertEqual((self.root / 'data/app.so').read_bytes(), b'old')
            self.parent.terminate()
            self.parent.wait(timeout=10)

    def test_success_waits_replaces_restarts_and_keeps_backup(self):
        self.start()
        self.assertEqual(self.helper.wait(timeout=20), 0)
        self.assertEqual((self.root / 'data/app.so').read_bytes(), b'new')
        self.assertEqual((self.stage / 'backup/data/app.so').read_bytes(), b'old')
        self.assertEqual((self.root / 'my-notes.md').read_text(), 'keep my notes')
        self.assertTrue((self.stage / 'complete').exists())

    def test_locked_file_rolls_back_partial_replacement(self):
        handle = KERNEL.CreateFileW(str(self.root / 'flutter_windows.dll'),
                                   0x80000000, 1, None, 3, 0, None)
        self.assertNotEqual(handle, ctypes.c_void_p(-1).value)
        try:
            self.start()
            self.assertEqual(self.helper.wait(timeout=20), 1)
        finally:
            KERNEL.CloseHandle(handle)
        wait_for(self.root / 'recovered.txt')
        self.assertEqual((self.root / 'data/app.so').read_bytes(), b'old')
        self.assertEqual((self.root / 'flutter_windows.dll').read_bytes(), b'old')
        self.assertIn('Windows blocked', (self.stage / 'error.txt').read_text())
        self.assertEqual((self.root / 'my-notes.md').read_text(), 'keep my notes')

    def test_failed_launch_restores_previous_version(self):
        shutil.copy2(BIN / 'updater_test_bad_app.exe', self.payload / 'actionnotes.exe')
        self.start()
        self.assertEqual(self.helper.wait(timeout=20), 1)
        wait_for(self.root / 'recovered.txt')
        self.assertEqual((self.root / 'data/app.so').read_bytes(), b'old')
        self.assertIn('did not finish starting', (self.stage / 'error.txt').read_text())

    def test_incomplete_payload_leaves_running_app_alone(self):
        (self.payload / 'flutter_windows.dll').unlink()
        self.start(wait_ready=False)
        self.assertEqual(self.helper.wait(timeout=10), 1)
        self.assertIsNone(self.parent.poll())
        self.assertFalse((self.stage / 'ready').exists())
        self.assertEqual((self.root / 'data/app.so').read_bytes(), b'old')


if __name__ == '__main__':
    unittest.main()
