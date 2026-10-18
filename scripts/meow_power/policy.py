class Policy:
    def __init__(self, warn=75, throttle=80, stop=85, cap=1008000,
                 hot_hold_seconds=4,cool_hold_seconds=30,low_voltage_mv=3400,
                 low_voltage_hold_seconds=10,recover_c=75):
        self.warn, self.throttle, self.stop, self.cap = warn, throttle, stop, cap
        self.since = {}
        self.throttled = False
        self.cooldown = False
        self.hot_hold=hot_hold_seconds
        self.cool_hold=cool_hold_seconds
        self.low_voltage=low_voltage_mv
        self.low_hold=low_voltage_hold_seconds
        self.recover=recover_c

    def held(self, key, condition, now, duration):
        if not condition:
            self.since.pop(key, None)
            return False
        self.since.setdefault(key, now)
        return now - self.since[key] >= duration

    def update(self, now, temperature, voltage=None, current=None):
        known = temperature is not None
        throttle = self.held('hot', known and temperature >= self.throttle, now, self.hot_hold)
        stop = self.held('critical', known and temperature >= self.stop, now, self.hot_hold)
        if throttle: self.throttled = True
        stop_games = stop and not self.cooldown
        if stop: self.cooldown = True
        restore = self.held('cool', known and temperature < self.recover, now, self.cool_hold)
        restore = restore and (self.throttled or self.cooldown)
        if restore: self.throttled = self.cooldown = False
        low = self.held('low', voltage is not None and current is not None and voltage <= self.low_voltage and current < -50, now, self.low_hold)
        status = ('cooldown' if self.cooldown else 'throttled' if self.throttled else
                  'sensor-error' if not known else 'warm' if temperature >= self.warn else 'normal')
        messages = {'normal':'电源监控正常', 'warm':'设备温度偏高，请注意散热',
                    'throttled':'设备过热，已请求限制 CPU 频率', 'cooldown':'过热已停止游戏，请等待设备冷却',
                    'sensor-error':'无法读取板载温度，保护状态未解除'}
        if not known:
            messages[status]='无法读取板载温度，保护状态未解除；' + messages[status]
        return dict(status=status, message=messages[status], stopGames=stop_games,
                    limit=self.throttled, restore=restore, lowBattery=low)
