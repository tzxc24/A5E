#!/usr/bin/env python3
"""Keep Onboard reachable in the dedicated X11 session without a WM."""
import ctypes as c
import ctypes.util
import os
import sys
import time

x = c.CDLL(ctypes.util.find_library('X11'))
class ClassHint(c.Structure):
    _fields_ = [('name', c.c_void_p), ('klass', c.c_void_p)]
x.XOpenDisplay.argtypes = [c.c_char_p]; x.XOpenDisplay.restype = c.c_void_p
x.XDefaultRootWindow.argtypes = [c.c_void_p]; x.XDefaultRootWindow.restype = c.c_ulong
x.XQueryTree.argtypes = [c.c_void_p, c.c_ulong, c.POINTER(c.c_ulong), c.POINTER(c.c_ulong), c.POINTER(c.POINTER(c.c_ulong)), c.POINTER(c.c_uint)]
x.XGetClassHint.argtypes = [c.c_void_p, c.c_ulong, c.POINTER(ClassHint)]
x.XRaiseWindow.argtypes = [c.c_void_p, c.c_ulong]
x.XFree.argtypes = [c.c_void_p]; x.XFlush.argtypes = [c.c_void_p]
x.XCloseDisplay.argtypes = [c.c_void_p]
handler_type = c.CFUNCTYPE(c.c_int, c.c_void_p, c.c_void_p)
handler = handler_type(lambda display, event: 0)
x.XSetErrorHandler(handler)
display = x.XOpenDisplay(os.environ.get('DISPLAY', ':1').encode())
if not display:
    sys.exit(1)
try:
    root = x.XDefaultRootWindow(display)
    while True:
        try: os.kill(int(sys.argv[1]), 0)
        except ProcessLookupError: break
        returned_root, parent = c.c_ulong(), c.c_ulong()
        children, count = c.POINTER(c.c_ulong)(), c.c_uint()
        if x.XQueryTree(display, root, c.byref(returned_root), c.byref(parent), c.byref(children), c.byref(count)):
            for i in range(count.value):
                hint = ClassHint()
                if x.XGetClassHint(display, children[i], c.byref(hint)):
                    klass = c.string_at(hint.klass).lower() if hint.klass else b''
                    if b'onboard' in klass:
                        x.XRaiseWindow(display, children[i])
                    if hint.name: x.XFree(hint.name)
                    if hint.klass: x.XFree(hint.klass)
            if children: x.XFree(children)
        x.XFlush(display)
        time.sleep(0.5)
finally:
    x.XCloseDisplay(display)
