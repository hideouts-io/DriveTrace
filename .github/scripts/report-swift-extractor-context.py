import json
import re
import subprocess
import sys
from pathlib import Path
from typing import TypedDict


class SwiftExtractorContext(TypedDict):
    """Allowlisted metadata from external CodeQL logs; excludes commands and messages."""

    sdk_version: str
    examined_log_count: int
    matching_diagnostic_log_count: int
    module_names: list[str]
    unrecognized_module_name_count: int
    sdk_identifiers: list[str]
    selected_compiler_flags: list[str]
    diagnostic_context_status: str


def summarize_logs(log_texts: tuple[str, ...], sdk_version: str) -> SwiftExtractorContext:
    """Extract bounded context only from logs containing the known ambiguity."""
    matching: tuple[str, ...] = tuple(text for text in log_texts if "reference to 'NSAccessibilityElement' is ambiguous" in text)
    module_names: set[str] = set()
    sdk_identifiers: set[str] = set()
    selected_flags: set[str] = set()
    unrecognized_names: set[str] = set()
    allowed_modules: frozenset[str] = frozenset(
        ("DriveCore", "DriveTrace", "CSQLite", "AppKit", "Accessibility", "Foundation", "SwiftUI", "SwiftUICore", "Darwin", "ObjectiveC")
    )
    allowed_flags: tuple[str, ...] = (
        "-emit-module", "-parse-as-library", "-enable-objc-interop",
        "-disable-implicit-swift-modules", "-fno-implicit-modules",
        "-fno-implicit-module-maps", "-explicit-swift-module-map-file",
    )
    for text in matching:
        for name in re.findall(r"-module-name[\s\"'=]+([A-Za-z_][A-Za-z0-9_.]*)", text):
            if name in allowed_modules:
                module_names.add(name)
            else:
                unrecognized_names.add(name)
        sdk_identifiers.update(re.findall(r"MacOSX(?:[0-9]+(?:\.[0-9]+)*)?\.sdk", text))
        selected_flags.update(flag for flag in allowed_flags if re.search(r"(?<![A-Za-z0-9_-])" + re.escape(flag) + r"(?=$|[\s'\"])", text))
    return {
        "sdk_version": sdk_version,
        "examined_log_count": len(log_texts),
        "matching_diagnostic_log_count": len(matching),
        "module_names": sorted(module_names),
        "unrecognized_module_name_count": len(unrecognized_names),
        "sdk_identifiers": sorted(sdk_identifiers),
        "selected_compiler_flags": sorted(selected_flags),
        "diagnostic_context_status": "matching_logs_found" if matching else "known_diagnostic_not_recorded_in_selected_logs",
    }


def read_log_texts(log_directory: Path) -> tuple[str, ...]:
    """Read regular extractor logs with explicit file count and byte limits."""
    if not log_directory.is_dir() or log_directory.is_symlink():
        raise ValueError("CodeQL Swift log directory is missing or is a symbolic link")
    paths: tuple[Path, ...] = tuple(sorted(log_directory.rglob("*.log")))
    if not paths or len(paths) > 500:
        raise ValueError("CodeQL Swift log file count must be between 1 and 500")
    resolved_root: Path = log_directory.resolve(strict=True)
    for path in paths:
        relative_parts: tuple[str, ...] = path.relative_to(log_directory).parts
        components: tuple[Path, ...] = tuple(log_directory.joinpath(*relative_parts[:index]) for index in range(1, len(relative_parts) + 1))
        if any(component.is_symlink() for component in components):
            raise ValueError("CodeQL Swift log files and parent directories must not be symbolic links")
        if not path.is_file() or not path.resolve(strict=True).is_relative_to(resolved_root):
            raise ValueError("CodeQL Swift logs must be regular files within the verified log directory")
    sizes: tuple[int, ...] = tuple(path.stat().st_size for path in paths)
    if any(size > 20_000_000 for size in sizes) or sum(sizes) > 80_000_000:
        raise ValueError("CodeQL Swift log input exceeds the bounded byte limit")
    return tuple(path.read_text(encoding="utf-8") for path in paths)


def write_context(log_directory: Path, report_path: Path) -> None:
    """Write only SDK, module, flag and count metadata; never forward raw logs."""
    sdk_version: str = subprocess.check_output(
        ("/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version"), text=True, timeout=15
    ).strip()
    if re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,2}", sdk_version) is None:
        raise ValueError("Apple SDK command returned an invalid version format")
    context: SwiftExtractorContext = summarize_logs(read_log_texts(log_directory), sdk_version)
    with report_path.open("x", encoding="utf-8") as output:
        output.write(json.dumps(context, sort_keys=True) + "\n")
    print(json.dumps(context, sort_keys=True))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise ValueError("Expected the CodeQL Swift log directory and task report output path")
    write_context(Path(sys.argv[1]), Path(sys.argv[2]))
