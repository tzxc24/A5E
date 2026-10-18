def sample(read):
    errors=[]
    def get(address, register, length=2):
        try: return read(address, register, length)
        except (OSError, ValueError) as exc:
            errors.append('%02x:%02x %s' % (address, register, exc))
            return None
    gauge={r:get(0x55,r) for r in (6,8,10,12,16,18,20,44,46,58,60)}
    identity=get(0x6b,11,1)
    charger={r:get(0x6b,r,1) for r in (0,2,8,9)} if identity is not None and identity & 0x7c == 0x14 else {}
    def valid(value, low, high): return value if value is not None and low <= value <= high else -1
    voltage=valid(gauge[8],2000,5000)
    raw_current=gauge[12]
    current=(raw_current-65536 if raw_current >= 32768 else raw_current) if raw_current is not None else None
    current_valid=current is not None and abs(current) <= 20000
    soc=valid(gauge[44],0,100)
    rm=valid(gauge[16],0,30000)
    fcc=valid(gauge[18],1,30000)
    design=valid(gauge[60],1,30000)
    confidence='unavailable' if soc < 0 else 'unverified'
    inconsistent=rm >= 0 and fcc > 0 and (rm > fcc or (soc >= 0 and abs(100.0*rm/fcc-soc)>2))
    if inconsistent: confidence='inconsistent'
    status_byte=charger.get(8)
    external_known=status_byte is not None
    external=external_known and bool(status_byte & 4)
    charge_state=((status_byte >> 3) & 3) if external_known else None
    charging=external and charge_state in (1,2)
    conflict=(external_known and charge_state in (1,2) and not external) or (current_valid and external_known and
              ((charging and current < -50) or (not charging and current > 50)))
    if conflict: errors.append('充电器状态与电流冲突')
    status='Unknown'
    if current_valid and external_known and not conflict:
        status='Charging' if charging else 'Discharging' if current < -50 else 'Full' if ((status_byte >> 3)&3)==3 else 'Not charging'
    temp=gauge[6]
    temp_c=temp/10.0-273.15 if temp is not None and 2331 <= temp <= 3731 else -273.15
    fault=charger.get(9)
    charge_fault=('normal','input-fault','thermal-shutdown','safety-timer')[(fault >> 4)&3] if fault is not None else 'unknown'
    zone={0:'Normal',2:'Warm',3:'Cool',5:'Cold',6:'Hot'}.get(fault&7,'Unknown') if fault is not None else 'Unknown'
    if fault:
        errors.append('充电器故障 REG09=0x%02x，充电故障=%s，NTC=%s' % (fault,charge_fault,zone))
    return dict(batteryAvailable=voltage>=0, gaugeCommunication=gauge[6] is not None,
        gaugeError='; '.join(errors), batteryPercent=soc, batteryStatus=status,
        batteryCharging=status=='Charging', chargerAvailable=bool(charger),
        externalPowerPresent=external, batteryTemperatureC=temp_c, chargeTemperatureZone=zone,
        batteryVoltageMv=voltage, batteryCurrentMa=current if current_valid else 0,
        batteryRawVoltageMv=gauge[8] if gauge[8] is not None else -1,
        batteryRawCurrentMa=current if current is not None else 0,
        batteryRemainingMah=rm,batteryFullChargeMah=fcc,batteryDesignCapacityMah=design,
        batteryHealth='需检查' if inconsistent else 'Unknown',
        chargerInputLimitMa=100+(charger[0]&31)*100 if charger.get(0) is not None else -1,
        chargerFastCurrentMa=(charger[2]&63)*60 if charger.get(2) is not None else -1,
        chargerFault=charger.get(9),
        powerManagement=dict(socConfidence=confidence,currentValid=current_valid,
            voltageValid=voltage>=0, externalPowerKnown=external_known and not conflict,
            chargerChargeFault=charge_fault,chargerNtcZone=zone,chargerFaultRaw=fault))

class I2CReader:
    """Only combined register-address/read transfers; never writes register values."""
    def __init__(self, path='/dev/i2c-1'): self.path=path
    def __call__(self,address,register,length):
        import ctypes
        import os
        try: import fcntl
        except ImportError as exc: raise OSError('Linux I2C 接口不可用') from exc
        class Message(ctypes.Structure):
            _fields_=[('addr',ctypes.c_uint16),('flags',ctypes.c_uint16),('len',ctypes.c_uint16),('buf',ctypes.POINTER(ctypes.c_ubyte))]
        class Transfer(ctypes.Structure):
            _fields_=[('msgs',ctypes.POINTER(Message)),('nmsgs',ctypes.c_uint32)]
        pointer=(ctypes.c_ubyte*1)(register)
        data=(ctypes.c_ubyte*length)()
        messages=(Message*2)(Message(address,0,1,pointer),Message(address,1,length,data))
        fd=os.open(self.path,os.O_RDWR|os.O_CLOEXEC)
        try: fcntl.ioctl(fd,0x0707,Transfer(messages,2))
        finally: os.close(fd)
        return int.from_bytes(bytes(data),'little')
