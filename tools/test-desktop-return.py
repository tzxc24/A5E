import os,shutil,subprocess,tempfile,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
BASH='C:/Program Files/Git/bin/bash.exe' if os.name=='nt' else shutil.which('sh')
class DesktopReturn(unittest.TestCase):
 def test_splash_once_per_runtime_directory(self):
  with tempfile.TemporaryDirectory(dir=ROOT/'tmp') as tmp:
   p=Path(tmp); script=(ROOT/'scripts/meow-display-launcher').read_text()
   script=script.replace('/etc/meow-os/display.conf',str(p/'absent.conf').replace('\\','/'))
   script=script.replace('/opt/meow-os/meow-os',"printf 'ARG:%s\\n'")
   launcher=p/'launcher.sh';launcher.write_text(script)
   env=dict(os.environ,XDG_RUNTIME_DIR=p.as_posix())
   first=subprocess.run([BASH,launcher.as_posix()],env=env,capture_output=True,text=True)
   second=subprocess.run([BASH,launcher.as_posix()],env=env,capture_output=True,text=True)
   self.assertEqual(first.returncode,0,first.stderr)
   self.assertNotIn('--skip-splash',first.stdout)
   self.assertIn('--skip-splash',second.stdout)
 def test_desktop_stop_keeps_graphics(self):
  unit=(ROOT/'systemd/meow-os.service').read_text()
  self.assertIn('RuntimeDirectoryPreserve=yes',unit)
  self.assertNotIn('vt_mode.py text',unit)
if __name__=='__main__':unittest.main()
