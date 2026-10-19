"""Offline: the history schema, without touching the stored file."""
import importlib.machinery
import importlib.util
import os
import sys

sys.dont_write_bytecode = True

path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bin", "inair-history")
loader = importlib.machinery.SourceFileLoader("inair_history", path)
spec = importlib.util.spec_from_loader("inair_history", loader)
history = importlib.util.module_from_spec(spec)
loader.exec_module(history)

now = 1792432980000
# An index-only sample keeps its level's rank through the round trip.
rows = history.clean_samples([{"at": now - 1000, "pm25": None, "rank": 6}], now)
assert history.as_objects(rows)[0]["rank"] == 6, rows
# Rows stored before the rank existed still load, with no rank.
old = history.clean_samples([[now - 2000, 12.5, 20, 5.1, 90, 1010]], now)
assert old and old[0][1] == 12.5 and history.as_objects(old)[0]["rank"] is None, old
assert history.clean_samples([{"at": now, "rank": 9}], now)[0][-1] is None
print("history: all passed")
