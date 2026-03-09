#!/usr/bin/env python3
"""CLI voice coaching loop — run with: python3 voice-coach.py"""

import sys
from pathlib import Path

# Ensure package is importable from the voicelayer repo root
sys.path.insert(0, str(Path(__file__).parent))

from voice_coach.loop import run

if __name__ == "__main__":
    try:
        run()
    except KeyboardInterrupt:
        print("\n\nCoach: See you next time. Stay consistent! 🌟")
