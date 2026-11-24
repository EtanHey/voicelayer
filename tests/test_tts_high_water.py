import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'src'))
from tts_daemon import retire_over_high_water


def test_fake_rss_retires_only_above_limit():
    exits = []
    retire_over_high_water(lambda: 8 * 1024**3, exits.append)
    assert exits == []
    retire_over_high_water(lambda: 8 * 1024**3 + 1, exits.append)
    assert exits == [75]


def test_unknown_rss_keeps_daemon():
    exits = []
    retire_over_high_water(lambda: None, exits.append)
    assert exits == []

if __name__ == '__main__':
    test_fake_rss_retires_only_above_limit()
    test_unknown_rss_keeps_daemon()
    print('2 tests passed')
