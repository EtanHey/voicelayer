"""Shared input inventory for TLC recording and offline verification."""


def tracked_files(directory, root, manifest):
    return [directory / f'{manifest["module"]}.tla', directory / "checks.json", (root / "formal/check-model.py"), (root / "formal/check-model.py").with_name("graph_retention.py"),
               *directory.glob("*.cfg"), *(root / file for file in manifest["sources"]), root / "formal/receipt_support.py"]


def config_files(directory, manifest):
    """Config paths, including the legacy parakeet mutant subdirectory."""
    return {path.stem: path for path in directory.rglob('*.cfg')
            if 'results' not in path.relative_to(directory).parts
            and str(path.relative_to(directory)) not in manifest.get('unusedConfigs', [])}
