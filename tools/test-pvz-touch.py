import importlib.util
from pathlib import Path
import unittest
import sys

sys.dont_write_bytecode = True

spec=importlib.util.spec_from_file_location('touch',Path(__file__).resolve().parent.parent/'scripts/meow-pvz-touch.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)

class TouchTests(unittest.TestCase):
    def test_finds_game_below_fullscreen_wrapper(self):
        children={1:2,2:3,3:0};titles={1:'',2:'',3:'PvZ Portable'}
        self.assertEqual(m.game_window_at_pointer(1,children.get,titles.get),3)
    def test_keyboard_click_does_not_request_game_focus(self):
        children={1:4,4:5,5:0};titles={1:'',4:'Onboard',5:''}
        self.assertIsNone(m.game_window_at_pointer(1,children.get,titles.get))
    def test_disappearing_window_or_cycle_is_safe(self):
        self.assertIsNone(m.game_window_at_pointer(1,lambda window:None,lambda window:''))
        self.assertIsNone(m.game_window_at_pointer(1,lambda window:window,lambda window:''))
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
    def test_reused_slot_can_omit_unchanged_axis(self):
        s=m.TouchState();s.feed(3,57,1);s.feed(3,53,100);s.feed(3,54,200);s.feed(0,0,0)
        s.feed(3,57,-1);s.feed(0,0,0)
        s.feed(3,57,2);s.feed(3,53,110)
        self.assertEqual(s.feed(0,0,0),[('move',110,200),('button',1)])

if __name__=='__main__':unittest.main()
