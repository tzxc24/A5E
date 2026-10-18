#!/usr/bin/env python3
"""Session-local single-pointer adapter for SDL2's stale X11 touch coordinates."""
import os
import sys

def map_touch(x,y,x_range,y_range,width=1280,height=800):
    nx=max(0.,min(1.,(x-x_range[0])/float(x_range[1]-x_range[0])))
    ny=max(0.,min(1.,(y-y_range[0])/float(y_range[1]-y_range[0])))
    return round((1-ny)*(width-1)),round(nx*(height-1))

class TouchState:
    def __init__(self,initial=None):
        self.slot=0;self.slots={};self.positions={};self.primary=None;self.down=False
        if initial is not None:self.positions[0]={'x':initial[0],'y':initial[1]}
    def feed(self,kind,code,value):
        if kind==3:
            if code==47:self.slot=value
            elif code==57:
                if value<0:self.slots.pop(self.slot,None)
                else:self.slots[self.slot]=self.positions.setdefault(self.slot,{'x':None,'y':None})
            elif code in (53,54) and self.slot in self.slots:
                self.slots[self.slot]['x' if code==53 else 'y']=value
        if kind!=0 or code!=0:return []
        actions=[]
        if self.primary not in self.slots:
            if self.down:actions.append(('button',0));self.down=False
            self.primary=min(self.slots) if self.slots else None
        if self.primary is not None:
            point=self.slots[self.primary]
            if point['x'] is not None and point['y'] is not None:
                actions.append(('move',point['x'],point['y']))
                if not self.down:actions.append(('button',1));self.down=True
        return actions

def main():
    import array
    import ctypes as c
    import ctypes.util
    import fcntl
    import select
    import struct
    import signal
    x=c.CDLL(ctypes.util.find_library('X11'));t=c.CDLL(ctypes.util.find_library('Xtst'))
    x.XOpenDisplay.argtypes=[c.c_char_p];x.XOpenDisplay.restype=c.c_void_p
    x.XFlush.argtypes=[c.c_void_p];x.XCloseDisplay.argtypes=[c.c_void_p]
    t.XTestFakeMotionEvent.argtypes=[c.c_void_p,c.c_int,c.c_int,c.c_int,c.c_ulong]
    t.XTestFakeButtonEvent.argtypes=[c.c_void_p,c.c_uint,c.c_int,c.c_ulong]
    display=x.XOpenDisplay(os.environ.get('DISPLAY',':1').encode())
    if not display:raise RuntimeError('X display unavailable')
    fd=os.open(sys.argv[1],os.O_RDONLY|os.O_NONBLOCK)
    current={}
    def axis(code):
        values=array.array('i',[0]*6)
        fcntl.ioctl(fd,0x80184500+0x40+code,values,True)
        if values[2]<=values[1]:raise RuntimeError('Invalid touchscreen axis range')
        current[code]=values[0]
        return values[1],values[2]
    xr,yr=axis(53),axis(54)
    print('PVZ_TOUCH_READY',xr,yr,flush=True)
    poll=select.poll();poll.register(fd,select.POLLIN)
    event=struct.Struct('llHHi');state=TouchState((current[53],current[54]))
    def stop(signum,frame):raise SystemExit(0)
    signal.signal(signal.SIGTERM,stop);signal.signal(signal.SIGINT,stop)
    try:
        while True:
            try:os.kill(int(sys.argv[2]),0)
            except ProcessLookupError:break
            if not poll.poll(1000):continue
            try:batch=os.read(fd,event.size*64)
            except BlockingIOError:continue
            if not batch:break
            for offset in range(0,len(batch),event.size):
                _,_,kind,code,value=event.unpack_from(batch,offset)
                # A dropped evdev packet cannot leave a mouse button held.
                if kind==0 and code==3:
                    t.XTestFakeButtonEvent(display,1,0,0);state=TouchState();x.XFlush(display);continue
                for action in state.feed(kind,code,value):
                    if action[0]=='move':
                        px,py=map_touch(action[1],action[2],xr,yr)
                        t.XTestFakeMotionEvent(display,-1,px,py,0)
                    else:t.XTestFakeButtonEvent(display,1,action[1],0)
                if kind==0 and code==0:x.XFlush(display)
    finally:
        t.XTestFakeButtonEvent(display,1,0,0);x.XFlush(display)
        os.close(fd);x.XCloseDisplay(display)

if __name__=='__main__':main()
