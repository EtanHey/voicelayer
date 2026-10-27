import ast
import re
from pathlib import Path


def check_admission(nodes):
    source = (Path(__file__).resolve().parents[2] / "flow-bar/Sources/VoiceBarUI/VoiceState.swift").read_text()
    guard, = re.findall(r"if replacing, ([^\n]+) \{\s*stopSelectionRead\(\)\s*return\s*\}", source)
    expression = guard.replace("normalized.isEmpty", "empty").replace("&&", " and ").replace("||", " or ").replace("!", " not ").strip()
    tree = ast.parse(expression, mode="eval")
    for node in ast.walk(tree):
        assert isinstance(node, (ast.Expression, ast.BoolOp, ast.UnaryOp, ast.Name, ast.Load, ast.And, ast.Or, ast.Not)), "Unrecognised Swift admission guard"
        if isinstance(node, ast.Name):
            assert node.id in {"fromClipboard", "empty", "sameSelection", "samePlaying"}
    code = compile(tree, "Swift admission Boolean projection", "eval")
    count = 0
    for label in nodes.values():
        number = lambda key: int(re.search(rf"\b{key} = (\d+)", label)[1])
        if number("steps") != 2:
            continue
        latest, playing, queued, text = map(number, ("latest", "playing", "queued", "selection"))
        flags = dict(fromClipboard=False, empty=False, sameSelection=text == (latest or playing),
                     samePlaying=bool(latest) and text == playing)
        actual = bool(latest or playing or queued) and eval(code, {"__builtins__": {}}, flags)
        expected = re.search(r"\bstopped = (TRUE|FALSE)", label)[1] == "TRUE"
        assert actual == expected, f"Swift admission mismatch: latest={latest}, playing={playing}, queued={queued}, input={text}"
        count += 1
    assert count == 192, f"Expected all 4 x 4 x 4 x 3 admission snapshots, got {count}"
    print(f"PASS: {count} admission snapshots match the extracted Swift Boolean guard (not Swift runtime)", flush=True)
