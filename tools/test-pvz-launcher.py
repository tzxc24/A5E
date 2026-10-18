import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
BASH = 'C:/Program Files/Git/bin/bash.exe' if os.name == 'nt' else shutil.which('bash')

class LauncherPreflight(unittest.TestCase):
    def setUp(self):
        (ROOT / 'tmp').mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=ROOT / 'tmp')
        self.folder = Path(self.temp.name)
        (self.folder / 'properties').mkdir()
        binary = self.folder / 'pvz-portable'
        binary.write_text('#!/bin/sh\nexit 0\n')
        binary.chmod(0o755)
        (self.folder / 'main.pak').write_bytes(b'fixture')
        self.bin = self.folder / 'bin'; self.bin.mkdir()
        for name in ['Xorg','xrandr','xinput','xwininfo','setpriv','xset','python3']:
            p=self.bin/name;p.write_text('#!/bin/sh\nexit 0\n');p.chmod(0o755)
    def tearDown(self): self.temp.cleanup()
    def check(self):
        env=os.environ.copy()
        env['MEOW_PVZ_DIR']=self.folder.as_posix()
        env['PATH']=str(self.bin)+os.pathsep+env['PATH']
        return subprocess.run([BASH,(ROOT/'scripts/meow-pvz-launch.sh').as_posix(),'--check'],env=env,capture_output=True,text=True,encoding='utf-8',errors='replace')
    def test_available_resources_pass_without_starting_display(self):
        result=self.check();self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('PVZ_PREFLIGHT_OK',result.stdout)
    def test_missing_assets_fail_before_display_handoff(self):
        (self.folder/'main.pak').unlink()
        result=self.check();self.assertNotEqual(result.returncode,0)
        self.assertIn('main.pak',result.stderr)
    def test_missing_engine_fails_before_display_handoff(self):
        (self.folder/'pvz-portable').unlink()
        result=self.check();self.assertNotEqual(result.returncode,0)
        self.assertIn('pvz-portable',result.stderr)

if __name__=='__main__': unittest.main()
