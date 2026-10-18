import sys
import unittest
import tempfile
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
tempfile.tempdir=str(Path(__file__).resolve().parents[1] / 'tmp')

class HardwareTests(unittest.TestCase):
    def test_lower_cap_and_boot_isolation(self):
        from meow_power.hardware import CpuLimiter
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            cpu=root/'devices/system/cpu/cpufreq/policy0'
            cpu.mkdir(parents=True)
            maximum=cpu/'scaling_max_freq'
            maximum.write_text('800000')
            state=root/'limits.json'
            limiter=CpuLimiter(root,state,'old')
            limiter.limit(1008000)
            self.assertEqual(maximum.read_text(),'800000')
            maximum.write_text('1800000')
            limiter.limit(1008000)
            self.assertFalse(CpuLimiter(root,state,'new').records)

    def test_failed_restore_keeps_original_for_retry(self):
        from meow_power.hardware import CpuLimiter
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            cpu=root/'devices/system/cpu/cpufreq/policy0'
            cpu.mkdir(parents=True)
            maximum=cpu/'scaling_max_freq'
            maximum.write_text('1800000')
            state=root/'limits.json'
            limiter=CpuLimiter(root,state,'boot')
            limiter.limit(1008000)
            maximum.unlink()
            self.assertTrue(limiter.restore())
            self.assertTrue(CpuLimiter(root,state,'boot').records)
            maximum.write_text('1008000')
            self.assertEqual(limiter.restore(),[])
            self.assertEqual(maximum.read_text(),'1800000')

    def test_once_cli_with_fake_paths_no_hardware(self):
        import json
        import subprocess
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            (root/'boot').write_text('fake-boot')
            (root/'uptime').write_text('100 200')
            zone=root/'class/thermal/thermal_zone0'
            zone.mkdir(parents=True)
            (zone/'type').write_text('cpu-thermal')
            (zone/'temp').write_text('40000')
            entry=Path(__file__).resolve().parents[1]/'scripts/meow-power.py'
            args=[sys.executable,str(entry),'--once','--config',str(root/'no-config'),
                  '--state-file',str(root/'state.json'),'--policy-state',str(root/'limits.json'),
                  '--sysfs-root',str(root),'--boot-id-file',str(root/'boot'),
                  '--uptime-file',str(root/'uptime'),'--i2c-device',str(root/'no-i2c')]
            result=subprocess.run(args,capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            state=json.loads((root/'state.json').read_text(encoding='utf-8'))
            self.assertEqual(state['bootId'],'fake-boot')
            self.assertEqual(state['powerManagement']['boardTemperatureC'],40)
            self.assertFalse(state['batteryAvailable'])
            args[2]='--allow-game'
            self.assertEqual(subprocess.run(args,capture_output=True).returncode,0)

    def test_cap_restart_restore_and_external_change(self):
        from meow_power.hardware import CpuLimiter
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            cpu=root/'devices/system/cpu/cpufreq/policy0'
            cpu.mkdir(parents=True)
            maximum=cpu/'scaling_max_freq'
            maximum.write_text('1800000')
            state=root/'limits.json'
            limiter=CpuLimiter(root,state,'boot')
            self.assertEqual(limiter.limit(1008000),[])
            self.assertEqual(maximum.read_text(),'1008000')
            restarted=CpuLimiter(root,state,'boot')
            restarted.limit(1008000)
            self.assertEqual(restarted.restore(),[])
            self.assertEqual(maximum.read_text(),'1800000')
            restarted.limit(1008000)
            maximum.write_text('800000')
            restarted.restore()
            self.assertEqual(maximum.read_text(),'800000')

    def test_freshness_gate(self):
        from meow_power.daemon import game_allowed
        state=dict(schemaVersion=1,bootId='a',sampleUptimeSeconds=10,powerManagement=dict(available=True,status='normal',boardTemperatureC=40))
        self.assertTrue(game_allowed(state,'a',16)[0])
        self.assertFalse(game_allowed(state,'a',16.1)[0])
        self.assertFalse(game_allowed(state,'b',11)[0])
        state['powerManagement']['status']='cooldown'
        self.assertFalse(game_allowed(state,'a',11)[0])

class PolicyTests(unittest.TestCase):
    def test_missing_sensor_keeps_throttle_and_resets_cool_timer(self):
        from meow_power.policy import Policy
        p=Policy()
        p.update(0,80)
        p.update(4,80)
        p.update(5,74)
        self.assertTrue(p.update(34,None)['limit'])
        p.update(35,74)
        self.assertFalse(p.update(64,74)['restore'])
        self.assertTrue(p.update(65,74)['restore'])

    def test_custom_thresholds_and_hold_times(self):
        from meow_power.policy import Policy
        p=Policy(hot_hold_seconds=6,cool_hold_seconds=40,low_voltage_mv=3500,low_voltage_hold_seconds=12,recover_c=70)
        p.update(0,80,3450,-100)
        self.assertFalse(p.update(4,80,3450,-100)['limit'])
        self.assertTrue(p.update(6,80,3450,-100)['limit'])
        self.assertTrue(p.update(12,80,3450,-100)['lowBattery'])
        p.update(13,69)
        self.assertFalse(p.update(52,69)['restore'])
        self.assertTrue(p.update(53,69)['restore'])

    def test_thresholds_and_sensor_loss(self):
        from meow_power.policy import Policy
        p = Policy()
        self.assertEqual(p.update(0, 80)['status'], 'warm')
        self.assertEqual(p.update(4, 80)['status'], 'throttled')
        self.assertEqual(p.update(5, 85)['status'], 'throttled')
        self.assertTrue(p.update(9, 85)['stopGames'])
        self.assertEqual(p.update(10, None)['status'], 'cooldown')
        p.update(11, 74)
        self.assertEqual(p.update(40, 74)['status'], 'cooldown')
        self.assertTrue(p.update(41, 74)['restore'])

    def test_low_voltage_requires_continuous_discharge(self):
        from meow_power.policy import Policy
        p = Policy()
        self.assertFalse(p.update(0, 40, 3400, -100)['lowBattery'])
        self.assertTrue(p.update(10, 40, 3400, -100)['lowBattery'])
        self.assertFalse(p.update(11, 40, 3400, None)['lowBattery'])

class TelemetryTests(unittest.TestCase):
    def test_conflict_invalid_capacity_and_fault_retained(self):
        from meow_power.telemetry import sample
        values={6:2981,8:3800,10:0,12:65436,16:1445,18:0,20:65436,44:49,46:100,58:0,60:65535}
        def read(address, register, length):
            if address==0x6b: return {11:0x14,0:0,2:0,8:0x14,9:0x80}[register]
            return values[register]
        state=sample(read)
        self.assertEqual(state['batteryStatus'],'Unknown')
        self.assertFalse(state['powerManagement']['externalPowerKnown'])
        self.assertEqual(state['chargerFault'],0x80)
        self.assertEqual(state['batteryFullChargeMah'],-1)
        self.assertEqual(state['batteryDesignCapacityMah'],-1)

    def test_read_only_correct_maps_and_signed_current(self):
        from meow_power.telemetry import sample
        reads=[]
        values={6:2981,8:3800,10:0,12:65436,16:1445,18:3000,20:65436,44:49,46:100,58:0,60:3000}
        def read(address, register, length):
            reads.append((address,register,length))
            if address == 0x6b:
                return {11:0x14,0:0,2:0,8:0,9:0}[register]
            return values[register]
        s=sample(read)
        self.assertEqual(s['batteryRemainingMah'],1445)
        self.assertEqual(s['batteryFullChargeMah'],3000)
        self.assertEqual(s['batteryCurrentMa'],-100)
        self.assertEqual(s['powerManagement']['socConfidence'],'unverified')
        self.assertNotIn((0x55,0x28,2),reads)
        self.assertNotIn((0x55,0x2a,2),reads)
        values[44]=90
        self.assertEqual(sample(read)['powerManagement']['socConfidence'],'inconsistent')

    def test_unavailable(self):
        from meow_power.telemetry import sample
        def read(*args): raise OSError('unavailable')
        s=sample(read)
        self.assertFalse(s['batteryAvailable'])
        self.assertEqual(s['batteryPercent'],-1)
        self.assertFalse(s['powerManagement']['currentValid'])

if __name__ == '__main__': unittest.main()
