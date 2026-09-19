
import re
import sys

with open('source/overlay/radar_overlay.m', 'r', encoding='utf-8', errors='replace') as f:
    text = f.read()

print('File read, size:', len(text))
