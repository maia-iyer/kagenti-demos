import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from src.greet import greet


class TestGreet(unittest.TestCase):
    def test_greet_produces_a_friendly_greeting(self):
        self.assertEqual(greet('world'), 'hello, world')


if __name__ == '__main__':
    unittest.main()
