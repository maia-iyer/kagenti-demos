import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from vendor import lib


def greet(name):
    return lib.old_name(name)
