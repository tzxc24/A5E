import json
import os
import subprocess
from pathlib import Path

def atomic_json(path, value, mode=0o644):
    path=Path(path)
    path.parent.mkdir(parents=True,exist_ok=True)
    temporary=path.with_name(path.name+'.tmp')
    fd=os.open(str(temporary),os.O_WRONLY|os.O_CREAT|os.O_TRUNC,mode)
    try:
        with os.fdopen(fd,'w',encoding='utf-8') as stream:
            json.dump(value,stream,ensure_ascii=False,allow_nan=False)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(str(temporary),mode)
        os.replace(str(temporary),str(path))
    finally:
        if temporary.exists(): temporary.unlink()

def root_owned(path):
    info=Path(path).stat()
    return os.name == 'nt' or (info.st_uid == 0 and info.st_mode & 0o022 == 0)

class CpuLimiter:
    def __init__(self, sysfs, state_path, boot):
        self.sysfs,self.path,self.boot=Path(sysfs),Path(state_path),boot
        self.records={}
        self.cooldown=False
        self.throttled=False
        self.restriction_reason='none'
        self._saved_payload=None
        if self.path.exists():
            if not root_owned(self.path): raise ValueError('CPU 状态文件必须由 root 所有且不可由其他用户写入')
            state=json.loads(self.path.read_text(encoding='utf-8'))
            if state.get('bootId') == boot:
                self.records=state.get('limits',{})
                self.cooldown=bool(state.get('cooldown',False))
                self.restriction_reason=state.get('restrictionReason','unknown')
                # Older/crash-interrupted states cannot prove that recorded caps
                # were sleep-only. Never clear a thermal latch on that evidence.
                self.throttled=(self.cooldown or bool(state.get('throttled',False)) or
                                (bool(self.records) and self.restriction_reason != 'sleep'))

    def save(self):
        state=dict(bootId=self.boot,limits=self.records,cooldown=self.cooldown,
                   throttled=self.throttled,restrictionReason=self.restriction_reason)
        # Serialize to detach the cached value from mutable nested records. Cache
        # only a successful commit, so failed writes are retried on the next poll.
        payload=json.dumps(state,sort_keys=True,allow_nan=False)
        if payload == self._saved_payload and self.path.exists(): return
        atomic_json(self.path,state,0o600)
        self._saved_payload=payload

    def limit(self, cap):
        errors=[]
        for path in self.sysfs.glob('devices/system/cpu/cpufreq/policy*/scaling_max_freq'):
            try:
                current=int(path.read_text().strip())
                key=str(path)
                record=self.records.get(key)
                if record and current not in (record['applied'],record.get('pending')):
                    # Another manager changed its limit: relinquish our baseline.
                    del self.records[key]
                    self.save()
                if key not in self.records and current > cap:
                    self.records[key]=dict(original=current,applied=current)
                if key in self.records:
                    record=self.records[key]
                    target=min(cap,record['original'])
                    if current == target == record['applied'] and 'pending' not in record:
                        continue
                    record['pending']=target
                    self.save()  # Journal ownership before changing hardware.
                    if current != target: path.write_text(str(target))
                    record['applied']=target
                    record.pop('pending',None)
                    self.save()
            except (OSError,ValueError) as exc: errors.append('限制 CPU 失败: %s' % exc)
        return errors

    def restore(self):
        errors=[]
        for key,record in list(self.records.items()):
            try:
                path=Path(key)
                # Never trust an arbitrary path from a persisted document.
                if path not in list(self.sysfs.glob('devices/system/cpu/cpufreq/policy*/scaling_max_freq')):
                    raise ValueError('CPU 状态路径无效')
                if int(path.read_text().strip()) in (record['applied'],record.get('pending')):
                    path.write_text(str(record['original']))
                del self.records[key]
                self.save()
            except (OSError,ValueError,KeyError) as exc: errors.append('恢复 CPU 失败: %s' % exc)
        return errors

def board_temperature(sysfs):
    readings=[]
    sources=[]
    errors=[]
    for zone in Path(sysfs).glob('class/thermal/thermal_zone*'):
        try:
            name=(zone/'type').read_text().strip()
            if not any(part in name.lower() for part in ('cpu','gpu','ddr')): continue
            temperature=float((zone/'temp').read_text().strip())/1000
            if not -40 <= temperature <= 150: raise ValueError('温度超出范围')
            readings.append(temperature)
            sources.append(name)
        except (OSError,ValueError) as exc: errors.append(str(exc))
    return (max(readings) if readings and not errors else None), ', '.join(sources), errors

def stop_games():
    try:
        result=subprocess.run(['systemctl','--no-block','stop','meow-pvz.service','meow-mindustry.service'],
                              capture_output=True,text=True,timeout=1)
        return ['停止游戏请求失败: %s' % result.stderr.strip()] if result.returncode else []
    except (OSError,subprocess.TimeoutExpired) as exc: return ['停止游戏请求失败: %s' % exc]
