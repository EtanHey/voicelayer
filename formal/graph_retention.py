"""Bound TLC DOT evidence to one failed run and retain the existing metadata rotation."""
from contextlib import contextmanager
from pathlib import Path
import tempfile
import shutil

MARKER = "FAILED-GRAPHS-KEPT"


def delete_graphs(run):
    for graph in run.rglob("*.dot"):
        graph.unlink()


def discard_failure(run):
    delete_graphs(run)
    (run / MARKER).unlink(missing_ok=True)


def sweep(root, keep_runs, keep=None):
    runs = [path for path in root.iterdir()
            if path.is_dir() and not path.is_symlink()
            and path.name.startswith(("run-", "tlc-"))]
    marked = sorted((path for path in runs if (path / MARKER).is_file()),
                    key=lambda path: ((path / MARKER).stat().st_mtime_ns, path.name), reverse=True)
    keep = keep or (marked[0] if marked else None)
    for run in runs:
        if run != keep:
            discard_failure(run)
    # Keep recent receipts without ever rotating out the surviving failure.
    newest = set(sorted(runs, key=lambda path: path.stat().st_mtime_ns, reverse=True)[:keep_runs])
    for run in runs:
        if run != keep and run not in newest:
            shutil.rmtree(run)


@contextmanager
def graph_run(root, prefix="run-", keep_runs=3):
    root = Path(root)
    root.mkdir(parents=True, exist_ok=True)
    sweep(root, keep_runs)
    run = Path(tempfile.mkdtemp(prefix=prefix, dir=root))
    succeeded = False
    try:
        yield run
        delete_graphs(run)
        succeeded = True
    finally:
        if not succeeded:
            (run / MARKER).write_text("Failed run: DOT graphs retained until the next failure.\n")
        sweep(root, keep_runs, keep=None if succeeded else run)
