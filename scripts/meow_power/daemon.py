import argparse
import json
import math
import sys
import time
from pathlib import Path
from .hardware import CpuLimiter, atomic_json, board_temperature, root_owned, stop_games
from .policy import Policy
from .telemetry import I2CReader, sample

def game_allowed(state, boot, uptime):
    try:
        age=uptime-state['sampleUptimeSeconds']
        pm=state['powerManagement']
        temperature=pm['boardTemperatureC']
        valid=(state['schemaVersion']==1 and state['bootId']==boot and 0 <= age <= 6
               and pm['available'] is True and pm['status'] in ('normal','warm','throttled')
               and isinstance(temperature,(int,float)) and math.isfinite(temperature)
               and -40 <= temperature < 85)
        return valid, '允许启动游戏' if valid else '电源状态不可用、过期或设备正在冷却，暂不能启动游戏'
    except (KeyError,TypeError,ValueError): return False,'电源状态快照无效，暂不能启动游戏'

def main(argv=None):
    parser=argparse.ArgumentParser(description='MeowOS 独立电源监控')
    modes=parser.add_mutually_exclusive_group()
    for name in ('once','allow-game','restore'): modes.add_argument('--'+name,action='store_true')
    for name,default in (('config','/etc/meow-os/power-management.json'),('state-file','/run/meow-power/state.json'),
                         ('policy-state','/var/lib/meow-power/cpu-limits.json'),('i2c-device','/dev/i2c-1'),
                         ('sysfs-root','/sys'),('boot-id-file','/proc/sys/kernel/random/boot_id'),('uptime-file','/proc/uptime')):
        parser.add_argument('--'+name,default=default)
    args=parser.parse_args(argv)
    boot=Path(args.boot_id_file).read_text().strip()
    def uptime(): return float(Path(args.uptime_file).read_text().split()[0])
    if args.allow_game:
        deadline=time.monotonic()+3
        while True:
            try: allowed,message=game_allowed(json.loads(Path(args.state_file).read_text(encoding='utf-8')),boot,uptime())
            except (OSError,ValueError): allowed,message=False,'电源服务尚未提供有效状态'
            if allowed or time.monotonic() >= deadline:
                print(message)
                return 0 if allowed else 1
            time.sleep(0.2)
    config={}
    config_path=Path(args.config)
    if config_path.exists():
        if not root_owned(config_path): raise ValueError('电源配置必须由 root 所有且不可由其他用户写入')
        config=json.loads(config_path.read_text(encoding='utf-8'))
    limiter=CpuLimiter(args.sysfs_root,args.policy_state,boot)
    policy=Policy(config.get('warning_c',75),config.get('throttle_c',80),config.get('stop_games_c',85),config.get('throttle_khz',1008000),
                  **{key:config[key] for key in ('hot_hold_seconds','cool_hold_seconds','low_voltage_mv','low_voltage_hold_seconds','recover_c') if key in config})
    policy.throttled=bool(limiter.records)
    policy.cooldown=limiter.cooldown
    if args.restore:
        temperature,_,errors=board_temperature(args.sysfs_root)
        # A single cool sample cannot establish the required 30 second recovery.
        if limiter.records or limiter.cooldown:
            print('保留保护限制；请运行电源服务确认连续冷却 30 秒后恢复',file=sys.stderr)
            return 1
        if temperature is None or temperature >= policy.warn:
            print('温度未知或偏高，拒绝恢复',file=sys.stderr)
            return 1
        return 0
    events=[]
    stop_pending=limiter.cooldown
    reader=I2CReader(args.i2c_device)
    while True:
        now=uptime()
        state=sample(reader)
        temperature,source,errors=board_temperature(args.sysfs_root)
        pm=state['powerManagement']
        decision=policy.update(now,temperature,state['batteryVoltageMv'] if pm['voltageValid'] else None,
                               state['batteryCurrentMa'] if pm['currentValid'] else None)
        if decision['limit']: errors.extend(limiter.limit(policy.cap))
        if policy.cooldown:
            limiter.cooldown=True
            limiter.save()
            # Retry failures while the latch remains active; fixed units only.
            if decision['stopGames'] or stop_pending:
                stop_errors=stop_games()
                stop_pending=bool(stop_errors)
                errors.extend(stop_errors)
        if decision['restore']:
            errors.extend(limiter.restore())
            if limiter.records:
                policy.throttled=True
                decision['status']='throttled'
            else:
                limiter.cooldown=False
                limiter.save()
        for error in errors:
            print(error,file=sys.stderr)
            events.append(error)
        if decision['stopGames']: events.append('设备持续过热，已请求停止游戏并进入冷却')
        if decision['lowBattery'] and (not events or events[-1] != '电池电压偏低，请连接电源'): events.append('电池电压偏低，请连接电源')
        events=events[-20:]
        pm.update(available=temperature is not None,status=decision['status'],message=decision['message'],
                  temperatureSource=source,boardTemperatureC=temperature if temperature is not None else -273.15,
                  lowBattery=decision['lowBattery'],lastEvent=events[-1] if events else '',events=events)
        state.update(schemaVersion=1,bootId=boot,sampleUptimeSeconds=now)
        atomic_json(args.state_file,state)
        if args.once: return 0
        time.sleep(config.get('sample_interval_seconds',2))

def entry():
    try: return main()
    except (OSError,ValueError,KeyError) as exc:
        print('电源监控失败: %s' % exc,file=sys.stderr)
        return 1
