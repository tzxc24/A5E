import importlib.util
from pathlib import Path
import unittest
import sys

sys.dont_write_bytecode = True

spec=importlib.util.spec_from_file_location('touch',Path(__file__).resolve().parent.parent/'scripts/meow-pvz-touch.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)

class TouchTests(unittest.TestCase):
    def test_rotated_corners(self):
        self.assertEqual(m.map_touch(0,0,(0,799),(0,1279)),(1279,0))
        self.assertEqual(m.map_touch(799,1279,(0,799),(0,1279)),(0,799))
    def test_taps_use_new_position_and_release(self):
        state=m.TouchState()
        for x,y in [(10,20),(600,900)]:
            state.feed(3,57,1);state.feed(3,53,x);state.feed(3,54,y)
            self.assertEqual(state.feed(0,0,0),[('move',x,y),('button',1)])
            state.feed(3,57,-1)
            self.assertEqual(state.feed(0,0,0),[('button',0)])
    def test_drag_and_second_finger(self):
        s=m.TouchState();s.feed(3,57,1);s.feed(3,53,10);s.feed(3,54,20);s.feed(0,0,0)
        s.feed(3,47,1);s.feed(3,57,2);s.feed(3,53,300);s.feed(3,54,400)
        self.assertEqual(s.feed(0,0,0),[('move',10,20)])
        s.feed(3,47,0);s.feed(3,53,15)
        self.assertEqual(s.feed(0,0,0),[('move',15,20)])

if __name__=='__main__':unittest.main()
