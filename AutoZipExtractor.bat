@echo off & if "%~1"=="" (start "" pythonw -x "%~f0" 2>nul || python -x "%~f0" || pause) else (python -x "%~f0" %*) & exit /b
"""Auto Zip Extractor - All-in-One Standalone Application
Extracts archives (.zip, .rar, .7z, .tar, .gz, etc.) to a dedicated folder with
subfolder options, conflict resolution, progress tracking, and history.
"""

from dataclasses import asdict, dataclass, field
from datetime import datetime
import json
import lzma
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import threading
import time
import tkinter as tk
from tkinter import filedialog, messagebox, ttk
from typing import Any, Callable, Dict, List, Optional, Tuple
import zipfile

VERSION = "1.0.0"

# Optional libraries
try:
    import py7zr  # type: ignore
    HAS_PY7ZR = True
except ImportError:
    HAS_PY7ZR = False

try:
    import rarfile  # type: ignore
    HAS_RARFILE = True
except ImportError:
    HAS_RARFILE = False

SUPPORTED_EXTENSIONS = {
    ".zip",
    ".rar",
    ".7z",
    ".tar",
    ".tar.gz",
    ".tgz",
    ".tar.bz2",
    ".tbz2",
    ".tar.xz",
    ".txz",
    ".gz",
    ".bz2",
    ".xz",
}

JUNK_FILENAMES = {".ds_store", "thumbs.db", "desktop.ini"}
JUNK_DIRS = {"__macosx"}


# ==============================================================================
# Helper Utilities & App Storage
# ==============================================================================

def get_app_storage_dir() -> Path:
    """Store config and history outside workspace so the folder stays clean."""
    import tempfile
    candidates = [
        Path(tempfile.gettempdir()) / "AutoZipExtractor",
        Path(os.environ.get("LOCALAPPDATA", "")) / "AutoZipExtractor",
        Path.home() / ".auto_zip_extractor",
    ]
    for d in candidates:
        try:
            if not str(d).strip():
                continue
            d.mkdir(parents=True, exist_ok=True)
            test_f = d / ".perm_check"
            test_f.write_text("ok")
            test_f.unlink()
            return d
        except Exception:
            continue
    return Path(tempfile.gettempdir()) / "AutoZipExtractor"


def format_bytes(num_bytes: int) -> str:
    """Format bytes to human readable format."""
    for unit in ["B", "KB", "MB", "GB"]:
        if num_bytes < 1024.0:
            return f"{num_bytes:.1f} {unit}"
        num_bytes /= 1024.0
    return f"{num_bytes:.1f} TB"


def get_default_downloads_folder() -> Path:
    """Detect user's Downloads folder on Windows and other OS."""
    if os.name == "nt":
        import winreg
        try:
            sub_key = r"SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders"
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, sub_key) as key:
                downloads_guid = "{374DE290-123F-4565-9164-39C4925E467B}"
                path, _ = winreg.QueryValueEx(key, downloads_guid)
                if path and Path(path).is_dir():
                    return Path(path)
        except Exception:
            pass

    home_downloads = Path.home() / "Downloads"
    if home_downloads.is_dir():
        return home_downloads
    return Path.home()


def get_default_extracted_folder() -> Path:
    """Default dedicated extraction folder: ~/Downloads/Extracted."""
    return get_default_downloads_folder() / "Extracted"


def open_in_file_manager(folder_path: Path | str) -> None:
    """Open folder in Windows Explorer or OS file manager."""
    p = Path(folder_path)
    if not p.exists():
        p.mkdir(parents=True, exist_ok=True)
    try:
        if sys.platform == "win32":
            os.startfile(str(p))
        elif sys.platform == "darwin":
            subprocess.Popen(["open", str(p)])
        else:
            subprocess.Popen(["xdg-open", str(p)])
    except Exception as e:
        messagebox.showerror("Error", f"Failed to open folder: {e}")


def get_archive_clean_stem(path: Path) -> str:
    """Extract clean folder stem without compound extensions like .tar.gz."""
    name = path.name
    lower = name.lower()
    for compound in [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.z"]:
        if lower.endswith(compound):
            return name[: -len(compound)]
    return path.stem


def is_archive_file(path: Path | str) -> bool:
    """Check if file has a supported archive extension."""
    p = Path(path)
    if not p.is_file():
        return False
    lower = p.name.lower()
    return any(lower.endswith(ext) for ext in SUPPORTED_EXTENSIONS)


def is_safe_path(base_dir: Path, target_path: Path) -> bool:
    """Prevent Zip-Slip directory traversal vulnerability."""
    try:
        resolved_base = base_dir.resolve()
        resolved_target = target_path.resolve()
        return (
            resolved_base == resolved_target
            or resolved_base in resolved_target.parents
        )
    except Exception:
        return False


def sanitize_rel_path(rel_path: str) -> str:
    """Sanitize path members to avoid leading slashes and drive letters."""
    norm = rel_path.replace("\\", "/").strip()
    while norm.startswith("/"):
        norm = norm[1:]
    if len(norm) > 1 and norm[1] == ":":
        norm = norm[2:].lstrip("/")
    return norm


def resolve_conflict_path(target_path: Path, conflict_mode: str) -> Tuple[Path, bool]:
    """Resolve file conflicts: rename, overwrite, or skip."""
    if not target_path.exists():
        return target_path, False

    if conflict_mode == "overwrite":
        return target_path, False
    elif conflict_mode == "skip":
        return target_path, True
    elif conflict_mode == "rename":
        parent = target_path.parent
        stem = target_path.stem
        suffix = target_path.suffix
        counter = 1
        while True:
            candidate = parent / f"{stem} ({counter}){suffix}"
            if not candidate.exists():
                return candidate, False
            counter += 1
    return target_path, False


def should_ignore_entry(rel_path: str, filter_junk: bool) -> bool:
    """Check if file is OS junk (macOS __MACOSX, .DS_Store, Thumbs.db)."""
    if not filter_junk:
        return False
    parts = rel_path.lower().replace("\\", "/").split("/")
    for p in parts:
        if p in JUNK_DIRS:
            return True
    filename = parts[-1] if parts else ""
    if filename in JUNK_FILENAMES or filename.startswith("._"):
        return True
    return False


def find_rar_extractor() -> Tuple[Optional[str], str]:
    """Find available RAR extractor tool.
    Returns (binary_path, tool_type) where tool_type is 'unrar', 'winrar', '7z', or 'tar'.
    """
    unrar_paths = [
        r"C:\Program Files\WinRAR\UnRAR.exe",
        r"C:\Program Files (x86)\WinRAR\UnRAR.exe",
        shutil.which("unrar"),
        shutil.which("UnRAR"),
    ]
    for p in unrar_paths:
        if p and Path(p).is_file():
            return str(p), "unrar"

    winrar_paths = [
        r"C:\Program Files\WinRAR\WinRAR.exe",
        r"C:\Program Files (x86)\WinRAR\WinRAR.exe",
        shutil.which("winrar"),
        shutil.which("WinRAR"),
    ]
    for p in winrar_paths:
        if p and Path(p).is_file():
            return str(p), "winrar"

    seven_paths = [
        r"C:\Program Files\7-Zip\7z.exe",
        r"C:\Program Files (x86)\7-Zip\7z.exe",
        shutil.which("7z"),
    ]
    for p in seven_paths:
        if p and Path(p).is_file():
            return str(p), "7z"

    tar_paths = [
        r"C:\Windows\System32\tar.exe",
        shutil.which("tar"),
    ]
    for p in tar_paths:
        if p and Path(p).is_file():
            return str(p), "tar"

    return None, ""


# ==============================================================================
# Settings & History Storage
# ==============================================================================

class ConfigManager:
    """Handles persistent settings in user profile."""

    def __init__(self):
        self.config_path = get_app_storage_dir() / "config.json"
        self.config: Dict[str, Any] = {
            "dedicated_folder": str(get_default_extracted_folder()),
            "create_subfolder": False,
            "conflict_mode": "rename",
            "delete_after_extract": False,
            "filter_junk": True,
        }
        self.load()

    def load(self) -> None:
        if self.config_path.exists():
            try:
                with open(self.config_path, "r", encoding="utf-8") as f:
                    data = json.load(f)
                    if isinstance(data, dict):
                        self.config.update(data)
            except Exception:
                pass

    def save(self) -> None:
        try:
            with open(self.config_path, "w", encoding="utf-8") as f:
                json.dump(self.config, f, indent=4)
        except Exception:
            pass

    def get(self, key: str, default: Any = None) -> Any:
        return self.config.get(key, default)

    def update(self, new_values: Dict[str, Any]) -> None:
        self.config.update(new_values)
        self.save()


@dataclass
class HistoryEntry:
    timestamp: str
    archive_name: str
    archive_path: str
    destination_folder: str
    files_extracted: int
    bytes_extracted: int
    duration_seconds: float
    status: str
    error_message: Optional[str] = None


class HistoryManager:
    """Stores history in user profile."""

    def __init__(self):
        self.history_file = get_app_storage_dir() / "extraction_history.json"
        self.entries: List[HistoryEntry] = []
        self.load()

    def load(self) -> None:
        if self.history_file.exists():
            try:
                with open(self.history_file, "r", encoding="utf-8") as f:
                    data = json.load(f)
                    self.entries = [HistoryEntry(**item) for item in data]
            except Exception:
                self.entries = []

    def save(self) -> None:
        try:
            recent = self.entries[-200:]
            with open(self.history_file, "w", encoding="utf-8") as f:
                json.dump([asdict(e) for e in recent], f, indent=2)
        except Exception:
            pass

    def add_entry(
        self,
        archive_path: Path | str,
        destination_folder: Path | str,
        files_extracted: int,
        bytes_extracted: int,
        duration_seconds: float,
        success: bool,
        error_message: Optional[str] = None,
    ) -> HistoryEntry:
        p = Path(archive_path)
        entry = HistoryEntry(
            timestamp=datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            archive_name=p.name,
            archive_path=str(p),
            destination_folder=str(destination_folder),
            files_extracted=files_extracted,
            bytes_extracted=bytes_extracted,
            duration_seconds=duration_seconds,
            status="Success" if success else "Failed",
            error_message=error_message,
        )
        self.entries.insert(0, entry)
        self.save()
        return entry

    def clear(self) -> None:
        self.entries = []
        self.save()


# ==============================================================================
# Archive Extraction Engine
# ==============================================================================

@dataclass
class ExtractionOptions:
    create_subfolder: bool = False
    conflict_mode: str = "rename"  # rename, overwrite, skip
    delete_after_extract: bool = False
    filter_junk: bool = True


@dataclass
class ExtractionResult:
    success: bool
    archive_path: Path
    destination: Path
    files_extracted: int = 0
    files_skipped: int = 0
    bytes_extracted: int = 0
    errors: List[str] = field(default_factory=list)
    duration_seconds: float = 0.0


class ArchiveExtractor:
    """Performs extraction with progress reporting and path security."""

    def __init__(
        self,
        progress_callback: Optional[Callable[[float, str, int, int], None]] = None,
        log_callback: Optional[Callable[[str, str], None]] = None,
    ):
        self.progress_callback = progress_callback
        self.log_callback = log_callback
        self._cancelled = False
        self._last_progress_time = 0.0

    def cancel(self) -> None:
        self._cancelled = True

    def _log(self, level: str, msg: str) -> None:
        if self.log_callback:
            self.log_callback(level, msg)

    def _update_progress(self, pct: float, item: str, idx: int, total: int, force: bool = False) -> None:
        now = time.time()
        if not force and idx < total and (now - self._last_progress_time) < 0.04:
            return
        self._last_progress_time = now
        if self.progress_callback:
            self.progress_callback(pct, item, idx, total)

    def extract(
        self,
        archive_path: Path | str,
        destination_dir: Path | str,
        options: Optional[ExtractionOptions] = None,
    ) -> ExtractionResult:
        self._cancelled = False
        start_time = time.time()
        archive_p = Path(archive_path).resolve()
        dest_base = Path(destination_dir).resolve()
        opt = options or ExtractionOptions()

        if not archive_p.exists():
            return ExtractionResult(
                success=False,
                archive_path=archive_p,
                destination=dest_base,
                errors=[f"File not found on disk: {archive_p.name} (File was deleted or moved)"],
            )

        if opt.create_subfolder:
            target_dir = dest_base / get_archive_clean_stem(archive_p)
        else:
            target_dir = dest_base

        target_dir.mkdir(parents=True, exist_ok=True)
        self._log("INFO", f"Extracting {archive_p.name} -> {target_dir}")

        res = ExtractionResult(success=False, archive_path=archive_p, destination=target_dir)
        lower_name = archive_p.name.lower()

        try:
            if lower_name.endswith(".zip"):
                self._extract_zip(archive_p, target_dir, opt, res)
            elif lower_name.endswith(".rar"):
                self._extract_rar(archive_p, target_dir, opt, res)
            elif any(
                lower_name.endswith(ext)
                for ext in [".tar", ".tar.gz", ".tgz", ".tar.bz2", ".tbz2", ".tar.xz", ".txz"]
            ):
                self._extract_tar(archive_p, target_dir, opt, res)
            elif lower_name.endswith(".7z"):
                self._extract_7z(archive_p, target_dir, opt, res)
            elif lower_name.endswith(".gz") and not lower_name.endswith(".tar.gz"):
                self._extract_single_gz(archive_p, target_dir, opt, res)
            elif lower_name.endswith(".xz") and not lower_name.endswith(".tar.xz"):
                self._extract_single_xz(archive_p, target_dir, opt, res)
            else:
                before_files = set(target_dir.rglob("*")) if target_dir.exists() else set()
                shutil.unpack_archive(str(archive_p), str(target_dir))
                new_files = [f for f in target_dir.rglob("*") if f.is_file() and f not in before_files]
                res.files_extracted = len(new_files) if new_files else 1
                res.bytes_extracted = sum(f.stat().st_size for f in new_files) or archive_p.stat().st_size

            res.duration_seconds = round(time.time() - start_time, 2)
            if not res.errors and res.files_extracted > 0:
                res.success = True
                self._log("SUCCESS", f"Extracted {res.files_extracted} files in {res.duration_seconds}s")
                if opt.delete_after_extract:
                    try:
                        archive_p.unlink()
                        self._log("INFO", f"Deleted original archive: {archive_p.name}")
                    except Exception as e:
                        self._log("WARNING", f"Could not delete archive: {e}")
            else:
                res.success = res.files_extracted > 0

        except Exception as e:
            res.errors.append(str(e))
            res.duration_seconds = round(time.time() - start_time, 2)
            self._log("ERROR", f"Failed to extract {archive_p.name}: {e}")

        return res

    def _extract_zip(
        self, archive_p: Path, target_dir: Path, opt: ExtractionOptions, res: ExtractionResult
    ) -> None:
        with zipfile.ZipFile(archive_p, "r") as zf:
            valid_members = [
                m for m in zf.infolist()
                if not m.is_dir() and not should_ignore_entry(m.filename, opt.filter_junk)
            ]
            total = len(valid_members)

            for idx, member in enumerate(valid_members, 1):
                if self._cancelled:
                    res.errors.append("Cancelled by user")
                    break

                if opt.create_subfolder:
                    clean_rel = sanitize_rel_path(member.filename)
                    target_file = target_dir / clean_rel
                else:
                    target_file = target_dir / Path(member.filename).name

                if not is_safe_path(target_dir, target_file):
                    res.errors.append(f"Skipped unsafe path '{member.filename}'")
                    continue

                dest_file, skip = resolve_conflict_path(target_file, opt.conflict_mode)
                if skip:
                    res.files_skipped += 1
                    continue

                dest_file.parent.mkdir(parents=True, exist_ok=True)
                with zf.open(member) as src, open(dest_file, "wb") as dst:
                    shutil.copyfileobj(src, dst, length=1024 * 1024)

                res.files_extracted += 1
                res.bytes_extracted += member.file_size
                pct = (idx / total) * 100 if total > 0 else 100
                self._update_progress(pct, member.filename, idx, total, force=(idx == total))

    def _extract_rar(
        self, archive_p: Path, target_dir: Path, opt: ExtractionOptions, res: ExtractionResult
    ) -> None:
        """Extract RAR archives using UnRAR, WinRAR, 7z, or tar."""
        # 1. Try python rarfile module if present
        if HAS_RARFILE:
            try:
                import rarfile
                with rarfile.RarFile(archive_p) as rf:
                    members = [
                        m for m in rf.infolist()
                        if not m.isdir() and not should_ignore_entry(m.filename, opt.filter_junk)
                    ]
                    total = len(members)
                    for idx, m in enumerate(members, 1):
                        if self._cancelled:
                            break
                        dest_file, skip = resolve_conflict_path(
                            target_dir / sanitize_rel_path(m.filename), opt.conflict_mode
                        )
                        if skip:
                            res.files_skipped += 1
                            continue
                        dest_file.parent.mkdir(parents=True, exist_ok=True)
                        with rf.open(m) as src, open(dest_file, "wb") as dst:
                            shutil.copyfileobj(src, dst)
                        res.files_extracted += 1
                        res.bytes_extracted += m.file_size
                        pct = (idx / total) * 100 if total > 0 else 100
                        self._update_progress(pct, m.filename, idx, total)
                    return
            except Exception:
                pass

        # 2. Use system binary: UnRAR, WinRAR, 7-Zip, or tar
        binary_path, tool_type = find_rar_extractor()
        if not binary_path:
            res.errors.append("No RAR extractor found (WinRAR/UnRAR/7-Zip/tar required).")
            return

        target_str = str(target_dir)
        if not target_str.endswith("\\") and not target_str.endswith("/"):
            target_str += "\\"

        extract_cmd = "x" if opt.create_subfolder else "e"
        if tool_type == "unrar":
            overwrite_flag = "-or" if opt.conflict_mode == "rename" else ("-o+" if opt.conflict_mode == "overwrite" else "-o-")
            cmd = [binary_path, extract_cmd, "-y", "-inul", overwrite_flag, str(archive_p), target_str]
        elif tool_type == "winrar":
            overwrite_flag = "-or" if opt.conflict_mode == "rename" else ("-o+" if opt.conflict_mode == "overwrite" else "-o-")
            cmd = [binary_path, extract_cmd, "-y", "-ibck", "-inul", overwrite_flag, str(archive_p), target_str]
        elif tool_type == "7z":
            overwrite_flag = "-aou" if opt.conflict_mode == "rename" else ("-aoa" if opt.conflict_mode == "overwrite" else "-aos")
            cmd = [binary_path, extract_cmd, "-y", "-bso0", "-bsp0", overwrite_flag, f"-o{target_dir}", str(archive_p)]
        elif tool_type == "tar":
            cmd = [binary_path, "-xf", str(archive_p), "-C", str(target_dir)]
        else:
            res.errors.append(f"Unsupported extractor: {tool_type}")
            return

        self._log("INFO", f"Extracting RAR with {tool_type}: {archive_p.name}")
        creationflags = 0x08000000 if os.name == "nt" else 0  # CREATE_NO_WINDOW

        # Get member list directly from archive to accurately count ONLY this archive's files
        archive_members = []
        try:
            if tool_type in ("unrar", "winrar"):
                list_cmd = [binary_path, "lb", "-c-", "-idq", str(archive_p)]
                lproc = subprocess.run(list_cmd, capture_output=True, text=True, creationflags=creationflags)
                if lproc.returncode == 0:
                    archive_members = [
                        line.strip()
                        for line in lproc.stdout.splitlines()
                        if line.strip() and not should_ignore_entry(line.strip(), opt.filter_junk)
                    ]
            elif tool_type == "7z":
                list_cmd = [binary_path, "l", "-ba", "-slt", str(archive_p)]
                lproc = subprocess.run(list_cmd, capture_output=True, text=True, creationflags=creationflags)
                if lproc.returncode == 0:
                    for line in lproc.stdout.splitlines():
                        if line.startswith("Path = "):
                            p_val = line[7:].strip()
                            if not should_ignore_entry(p_val, opt.filter_junk):
                                archive_members.append(p_val)
        except Exception:
            pass

        proc = subprocess.run(cmd, capture_output=True, text=True, creationflags=creationflags)

        if archive_members:
            res.files_extracted = len(archive_members)
            total_bytes = 0
            for m in archive_members:
                fname = Path(m).name if not opt.create_subfolder else sanitize_rel_path(m)
                dest_f = target_dir / fname
                try:
                    if dest_f.is_file():
                        total_bytes += dest_f.stat().st_size
                except Exception:
                    pass
            res.bytes_extracted = total_bytes or archive_p.stat().st_size
        else:
            # Fallback if member listing was unavailable
            res.files_extracted = 1
            res.bytes_extracted = archive_p.stat().st_size

        self._update_progress(100.0, archive_p.name, 1, 1)

        if proc.returncode != 0:
            err = proc.stderr.strip() or proc.stdout.strip() or "No files extracted from RAR"
            res.errors.append(err[:200])

    def _extract_tar(
        self, archive_p: Path, target_dir: Path, opt: ExtractionOptions, res: ExtractionResult
    ) -> None:
        with tarfile.open(archive_p, "r:*") as tf:
            members = [
                m for m in tf.getmembers()
                if m.isreg() and not should_ignore_entry(m.name, opt.filter_junk)
            ]
            total = len(members)

            for idx, member in enumerate(members, 1):
                if self._cancelled:
                    res.errors.append("Cancelled by user")
                    break

                if opt.create_subfolder:
                    clean_rel = sanitize_rel_path(member.name)
                    target_file = target_dir / clean_rel
                else:
                    target_file = target_dir / Path(member.name).name

                if not is_safe_path(target_dir, target_file):
                    res.errors.append(f"Skipped unsafe path '{member.name}'")
                    continue

                dest_file, skip = resolve_conflict_path(target_file, opt.conflict_mode)
                if skip:
                    res.files_skipped += 1
                    continue

                dest_file.parent.mkdir(parents=True, exist_ok=True)
                fobj = tf.extractfile(member)
                if fobj:
                    with open(dest_file, "wb") as dst:
                        shutil.copyfileobj(fobj, dst)
                    fobj.close()
                    res.files_extracted += 1
                    res.bytes_extracted += member.size

                pct = (idx / total) * 100 if total > 0 else 100
                self._update_progress(pct, member.name, idx, total)

    def _extract_single_gz(
        self, archive_p: Path, target_dir: Path, opt: ExtractionOptions, res: ExtractionResult
    ) -> None:
        import gzip
        dest_file, skip = resolve_conflict_path(target_dir / archive_p.stem, opt.conflict_mode)
        if not skip:
            with gzip.open(archive_p, "rb") as src, open(dest_file, "wb") as dst:
                shutil.copyfileobj(src, dst)
            res.files_extracted += 1
            res.bytes_extracted += dest_file.stat().st_size
        self._update_progress(100.0, archive_p.stem, 1, 1)

    def _extract_single_xz(
        self, archive_p: Path, target_dir: Path, opt: ExtractionOptions, res: ExtractionResult
    ) -> None:
        dest_file, skip = resolve_conflict_path(target_dir / archive_p.stem, opt.conflict_mode)
        if not skip:
            with lzma.open(archive_p, "rb") as src, open(dest_file, "wb") as dst:
                shutil.copyfileobj(src, dst)
            res.files_extracted += 1
            res.bytes_extracted += dest_file.stat().st_size
        self._update_progress(100.0, archive_p.stem, 1, 1)

    def _extract_7z(
        self, archive_p: Path, target_dir: Path, opt: ExtractionOptions, res: ExtractionResult
    ) -> None:
        if HAS_PY7ZR:
            try:
                import py7zr
                with py7zr.SevenZipFile(archive_p, mode="r") as z:
                    targets = [f for f in z.getnames() if not should_ignore_entry(f, opt.filter_junk)]
                    for idx, name in enumerate(targets, 1):
                        if self._cancelled:
                            break
                        z.extract(path=target_dir, targets=[name])
                        res.files_extracted += 1
                        self._update_progress((idx / len(targets)) * 100, name, idx, len(targets))
                    return
            except Exception:
                pass

        tar_exe = shutil.which("tar") or r"C:\Windows\System32\tar.exe"
        if Path(tar_exe).is_file():
            creationflags = 0x08000000 if os.name == "nt" else 0
            before_files = set(target_dir.rglob("*")) if target_dir.exists() else set()
            subprocess.run([tar_exe, "-xf", str(archive_p), "-C", str(target_dir)], capture_output=True, creationflags=creationflags)
            new_files = [f for f in target_dir.rglob("*") if f.is_file() and f not in before_files]
            res.files_extracted = len(new_files) if new_files else 1
            res.bytes_extracted = sum(f.stat().st_size for f in new_files) or archive_p.stat().st_size
            self._update_progress(100.0, archive_p.name, 1, 1)


# ==============================================================================
# Graphical User Interface
# ==============================================================================

class AutoZipExtractorGUI:
    """Modern single-window interface for Auto Zip Extractor."""

    def __init__(self, root: tk.Tk):
        self.root = root
        self.root.title("Auto Zip Extractor")
        self.root.geometry("860x660")
        self.root.minsize(760, 560)

        self.config_mgr = ConfigManager()
        self.history_mgr = HistoryManager()
        self.extractor = ArchiveExtractor(
            progress_callback=self._on_extract_progress,
            log_callback=self._on_extract_log,
        )

        self.selected_files: List[Path] = []
        self._is_extracting = False

        self._apply_styles()
        self._build_ui()
        self._load_saved_settings()

    def _apply_styles(self) -> None:
        self.style = ttk.Style()
        try:
            self.style.theme_use("clam")
        except Exception:
            pass

        self.bg_color = "#f4f6f9"
        self.card_bg = "#ffffff"
        self.primary_color = "#166534"       # Dark forest green for accents, headings, and active tabs
        self.primary_hover = "#14532d"       # Darker hover
        self.btn_green = "#15803d"           # Darker solid emerald green for buttons
        self.btn_green_hover = "#14532d"     # Hover state
        self.text_color = "#202124"

        self.root.configure(bg=self.bg_color)

        self.style.configure(".", background=self.bg_color, foreground=self.text_color, font=("Segoe UI", 9))
        self.style.configure("TFrame", background=self.bg_color)
        self.style.configure("TLabel", background=self.bg_color, foreground=self.text_color)

        self.style.configure(
            "Primary.TButton",
            font=("Segoe UI", 10, "bold"),
            background=self.btn_green,
            foreground="white",
            padding=(14, 6),
        )
        self.style.map("Primary.TButton", background=[("active", self.btn_green_hover), ("disabled", "#b0bec5")])

        self.style.configure("Action.TButton", font=("Segoe UI", 9, "normal"), padding=(8, 4))

        self.style.configure("TNotebook", background=self.bg_color, tabmargins=[2, 5, 2, 0])
        self.style.configure(
            "TNotebook.Tab",
            font=("Segoe UI", 10, "bold"),
            padding=[18, 6],
            background="#e0e0e0",
            foreground="#555555",
        )
        self.style.map(
            "TNotebook.Tab",
            background=[("selected", self.card_bg)],
            foreground=[("selected", self.primary_color)],
        )

        self.style.configure(
            "Treeview",
            background=self.card_bg,
            foreground=self.text_color,
            fieldbackground=self.card_bg,
            rowheight=26,
            font=("Segoe UI", 9),
        )
        self.style.configure("Treeview.Heading", font=("Segoe UI", 9, "bold"))

    def _build_ui(self) -> None:
        # Dedicated destination folder card directly at top (heading removed)
        self._build_dedicated_folder_card()

        # Tabs: Extract Files & History
        self.notebook = ttk.Notebook(self.root)
        self.notebook.pack(fill="both", expand=True, padx=16, pady=8)

        self.manual_tab = ttk.Frame(self.notebook, padding=12)
        self.notebook.add(self.manual_tab, text="  📦 Extract Files  ")
        self._build_manual_tab()

        self.history_tab = ttk.Frame(self.notebook, padding=12)
        self.notebook.add(self.history_tab, text="  📜 History  ")
        self._build_history_tab()

        # Status bar
        status_bar = ttk.Frame(self.root, relief="sunken", padding="8 4")
        status_bar.pack(fill="x", side="bottom")

        self.status_lbl = ttk.Label(status_bar, text="Ready. Select archive files to extract.", font=("Segoe UI", 9))
        self.status_lbl.pack(side="left")

    def _build_dedicated_folder_card(self) -> None:
        """Top card for choosing the dedicated destination folder with lock toggle."""
        card = tk.Frame(self.root, bg=self.card_bg, bd=1, relief="solid", padx=12, pady=10)
        card.pack(fill="x", padx=16, pady=(12, 4))

        top_row = tk.Frame(card, bg=self.card_bg)
        top_row.pack(fill="x", pady=(0, 6))

        tk.Label(
            top_row,
            text="🎯 Destination:",
            bg=self.card_bg,
            fg=self.primary_color,
            font=("Segoe UI", 10, "bold"),
        ).pack(side="left")

        input_row = tk.Frame(card, bg=self.card_bg)
        input_row.pack(fill="x")

        # Container frame that looks like an entry box with embedded eye icon inside
        self.entry_container = tk.Frame(input_row, bg="#ffffff", bd=1, relief="solid")
        self.entry_container.pack(side="left", fill="x", expand=True, padx=(0, 6))

        self.dedicated_folder_var = tk.StringVar()
        self.dedicated_entry = tk.Entry(
            self.entry_container,
            textvariable=self.dedicated_folder_var,
            font=("Segoe UI", 9),
            bg="#ffffff",
            fg=self.text_color,
            bd=0,
            relief="flat",
            highlightthickness=0,
        )
        self.dedicated_entry.pack(side="left", fill="x", expand=True, padx=(6, 2), pady=4)

        # Eye icon inside the entry box at the right edge
        self.is_dest_locked = True
        self.eye_btn = tk.Label(
            self.entry_container,
            text="👁",
            font=("Segoe UI", 11),
            bg="#ffffff",
            fg="#aaaaaa",
            cursor="hand2",
            padx=4,
        )
        self.eye_btn.pack(side="right", padx=(2, 6))
        self.eye_btn.bind("<Button-1>", lambda e: self._toggle_destination_lock())
        self.eye_btn.bind("<Enter>", self._on_eye_enter)
        self.eye_btn.bind("<Leave>", self._on_eye_leave)

        # Browse button (eye button removed from next to it)
        self.browse_btn = ttk.Button(
            input_row,
            text="📁 Browse...",
            style="Action.TButton",
            command=self._browse_dedicated_folder,
        )
        self.browse_btn.pack(side="left", padx=0)

    def _build_manual_tab(self) -> None:
        btn_bar = ttk.Frame(self.manual_tab)
        btn_bar.pack(fill="x", pady=(0, 8))

        ttk.Button(
            btn_bar, text="➕ Select Archive Files...", style="Action.TButton", command=self._add_archive_files
        ).pack(side="left", padx=(0, 6))

        ttk.Button(
            btn_bar, text="📁 Select Folder with Archives...", style="Action.TButton", command=self._add_folder_archives
        ).pack(side="left", padx=6)

        ttk.Button(
            btn_bar, text="🧹 Clear List", style="Action.TButton", command=self._clear_selected_files
        ).pack(side="left", padx=6)

        self.file_count_lbl = ttk.Label(btn_bar, text="0 archives selected", font=("Segoe UI", 9, "italic"))
        self.file_count_lbl.pack(side="right", padx=6)

        # File list treeview
        list_frame = ttk.Frame(self.manual_tab)
        list_frame.pack(fill="both", expand=True, pady=4)

        cols = ("name", "size", "path", "status")
        self.files_tree = ttk.Treeview(list_frame, columns=cols, show="headings", height=8)
        self.files_tree.heading("name", text="Archive File")
        self.files_tree.heading("size", text="Size")
        self.files_tree.heading("path", text="Source Path")
        self.files_tree.heading("status", text="Status")

        self.files_tree.column("name", width=220, anchor="w")
        self.files_tree.column("size", width=80, anchor="e")
        self.files_tree.column("path", width=360, anchor="w")
        self.files_tree.column("status", width=100, anchor="center")

        tree_scroll = ttk.Scrollbar(list_frame, orient="vertical", command=self.files_tree.yview)
        self.files_tree.configure(yscrollcommand=tree_scroll.set)

        self.files_tree.pack(side="left", fill="both", expand=True)
        tree_scroll.pack(side="right", fill="y")

        # Extraction Options Card
        options_card = tk.LabelFrame(
            self.manual_tab,
            text=" Extraction Options ",
            font=("Segoe UI", 9, "bold"),
            bg=self.card_bg,
            padx=10,
            pady=8,
        )
        options_card.pack(fill="x", pady=8)

        row1 = tk.Frame(options_card, bg=self.card_bg)
        row1.pack(fill="x", pady=2)

        self.opt_subfolder = tk.BooleanVar(value=False)
        tk.Checkbutton(
            row1,
            text="Create subfolders for each archive (Unchecked = All images/files extract directly here)",
            variable=self.opt_subfolder,
            bg=self.card_bg,
            font=("Segoe UI", 9),
        ).pack(side="left")

        self.opt_filter_junk = tk.BooleanVar(value=True)
        tk.Checkbutton(
            row1,
            text="Ignore macOS & system junk (__MACOSX, .DS_Store, Thumbs.db)",
            variable=self.opt_filter_junk,
            bg=self.card_bg,
            font=("Segoe UI", 9),
        ).pack(side="right")

        row2 = tk.Frame(options_card, bg=self.card_bg)
        row2.pack(fill="x", pady=2)

        tk.Label(row2, text="When files already exist:", bg=self.card_bg, font=("Segoe UI", 9)).pack(
            side="left", padx=(0, 6)
        )

        self.opt_conflict = tk.StringVar(value="rename")
        conflict_cb = ttk.Combobox(
            row2,
            textvariable=self.opt_conflict,
            values=["rename (Keep both, auto-number)", "overwrite (Replace existing)", "skip (Leave existing)"],
            state="readonly",
            width=32,
        )
        conflict_cb.current(0)
        conflict_cb.pack(side="left")

        self.opt_delete = tk.BooleanVar(value=False)
        tk.Checkbutton(
            row2,
            text="Delete archive after successful extraction",
            variable=self.opt_delete,
            bg=self.card_bg,
            fg="#c62828",
            font=("Segoe UI", 9),
        ).pack(side="right")

        # Action Buttons
        action_row = ttk.Frame(self.manual_tab)
        action_row.pack(fill="x", pady=4)

        self.extract_btn = ttk.Button(
            action_row, text="🚀 Extract All Files", style="Primary.TButton", command=self._start_manual_extraction
        )
        self.extract_btn.pack(side="left", padx=(0, 8))

        self.cancel_btn = ttk.Button(
            action_row, text="⏹ Cancel", style="Action.TButton", command=self._cancel_extraction, state="disabled"
        )
        self.cancel_btn.pack(side="left")

        # Time elapsed indicator badge beside the action buttons
        self.time_badge = tk.Label(
            action_row,
            text="",
            font=("Segoe UI", 9, "bold"),
            bg=self.bg_color,
            fg=self.primary_color,
            padx=10,
            pady=3,
        )
        self.time_badge.pack(side="left", padx=12)

        # Progress bar
        progress_frame = ttk.Frame(self.manual_tab)
        progress_frame.pack(fill="x", pady=4)

        self.progress_var = tk.DoubleVar(value=0)
        self.progress_bar = ttk.Progressbar(
            progress_frame, variable=self.progress_var, maximum=100, mode="determinate"
        )
        self.progress_bar.pack(fill="x", side="top", pady=(2, 2))

        self.progress_detail_lbl = ttk.Label(
            progress_frame, text="Ready to extract.", font=("Segoe UI", 8), foreground="#555555"
        )
        self.progress_detail_lbl.pack(side="left")

        # Activity log
        log_frame = ttk.Frame(self.manual_tab)
        log_frame.pack(fill="both", expand=True, pady=(4, 0))

        self.log_text = tk.Text(
            log_frame, height=7, font=("Consolas", 8), bg="#212529", fg="#f8f9fa", relief="solid", bd=1
        )
        log_scroll = ttk.Scrollbar(log_frame, orient="vertical", command=self.log_text.yview)
        self.log_text.configure(yscrollcommand=log_scroll.set)

        self.log_text.pack(side="left", fill="both", expand=True)
        log_scroll.pack(side="right", fill="y")

    def _build_history_tab(self) -> None:
        top_bar = ttk.Frame(self.history_tab)
        top_bar.pack(fill="x", pady=(0, 8))

        ttk.Label(top_bar, text="Past Extraction History", font=("Segoe UI", 10, "bold")).pack(side="left")

        ttk.Button(
            top_bar, text="📂 Open Selected Folder", style="Action.TButton", command=self._open_selected_history_folder
        ).pack(side="right", padx=4)

        ttk.Button(top_bar, text="🗑 Clear History", style="Action.TButton", command=self._clear_history).pack(
            side="right", padx=4
        )

        h_frame = ttk.Frame(self.history_tab)
        h_frame.pack(fill="both", expand=True)

        cols = ("timestamp", "archive", "dest", "files", "size", "status")
        self.history_tree = ttk.Treeview(h_frame, columns=cols, show="headings", height=15)
        self.history_tree.heading("timestamp", text="Date & Time")
        self.history_tree.heading("archive", text="Archive File")
        self.history_tree.heading("dest", text="Destination Folder")
        self.history_tree.heading("files", text="Files")
        self.history_tree.heading("size", text="Size")
        self.history_tree.heading("status", text="Status")

        self.history_tree.column("timestamp", width=130, anchor="center")
        self.history_tree.column("archive", width=180, anchor="w")
        self.history_tree.column("dest", width=280, anchor="w")
        self.history_tree.column("files", width=60, anchor="center")
        self.history_tree.column("size", width=80, anchor="e")
        self.history_tree.column("status", width=80, anchor="center")

        h_scroll = ttk.Scrollbar(h_frame, orient="vertical", command=self.history_tree.yview)
        self.history_tree.configure(yscrollcommand=h_scroll.set)

        self.history_tree.pack(side="left", fill="both", expand=True)
        h_scroll.pack(side="right", fill="y")

        self._refresh_history_tree()

    # --- Settings & Folder Management ---

    def _load_saved_settings(self) -> None:
        saved_dest = self.config_mgr.get("dedicated_folder") or str(get_default_extracted_folder())
        self.dedicated_folder_var.set(saved_dest)

        self.opt_subfolder.set(self.config_mgr.get("create_subfolder", False))
        self.opt_filter_junk.set(self.config_mgr.get("filter_junk", True))
        self.opt_delete.set(self.config_mgr.get("delete_after_extract", False))

        conflict_val = self.config_mgr.get("conflict_mode", "rename")
        if conflict_val == "overwrite":
            self.opt_conflict.set("overwrite (Replace existing)")
        elif conflict_val == "skip":
            self.opt_conflict.set("skip (Leave existing)")
        else:
            self.opt_conflict.set("rename (Keep both, auto-number)")

        self._update_destination_lock_state()

    def _toggle_destination_lock(self) -> None:
        """Toggle edit lock on the destination path entry and browse button."""
        self.is_dest_locked = not self.is_dest_locked
        self._update_destination_lock_state()

    def _update_destination_lock_state(self) -> None:
        """Update entry and button states based on lock status."""
        if self.is_dest_locked:
            self.entry_container.config(bg="#f8f9fa")
            self.dedicated_entry.config(state="readonly", readonlybackground="#f8f9fa", fg="#555555")
            self.eye_btn.config(text="👁", fg="#aaaaaa", bg="#f8f9fa")
            self.browse_btn.config(state="disabled")
            self._save_current_settings()
        else:
            self.entry_container.config(bg="#ffffff")
            self.dedicated_entry.config(state="normal", bg="#ffffff", fg=self.text_color)
            self.eye_btn.config(text="👁", fg=self.primary_color, bg="#ffffff")
            self.browse_btn.config(state="normal")

    def _on_eye_enter(self, event=None) -> None:
        if self.is_dest_locked:
            self.status_lbl.config(text="Path is locked (fixed). Click the eye icon to unlock and edit.")
        else:
            self.status_lbl.config(text="Path is unlocked (editable). Click the eye icon to lock and protect.")

    def _on_eye_leave(self, event=None) -> None:
        self.status_lbl.config(text="Ready. Select archive files to extract.")

    def _save_current_settings(self) -> None:
        conflict_raw = self.opt_conflict.get()
        if "overwrite" in conflict_raw:
            conflict_mode = "overwrite"
        elif "skip" in conflict_raw:
            conflict_mode = "skip"
        else:
            conflict_mode = "rename"

        self.config_mgr.update(
            {
                "dedicated_folder": self.dedicated_folder_var.get().strip(),
                "create_subfolder": self.opt_subfolder.get(),
                "filter_junk": self.opt_filter_junk.get(),
                "delete_after_extract": self.opt_delete.get(),
                "conflict_mode": conflict_mode,
            }
        )

    def _browse_dedicated_folder(self) -> None:
        if self.is_dest_locked:
            return
        folder = filedialog.askdirectory(
            title="Select Dedicated Extraction Folder",
            initialdir=self.dedicated_folder_var.get() or str(Path.home()),
        )
        if folder:
            was_locked = self.is_dest_locked
            if was_locked:
                self.dedicated_entry.config(state="normal")
            self.dedicated_folder_var.set(folder)
            if was_locked:
                self.dedicated_entry.config(state="readonly")
            self._save_current_settings()
            self.status_lbl.config(text=f"Destination set to: {folder}")

    # --- File Management & Batch Operations ---

    def _add_archive_files(self) -> None:
        files = filedialog.askopenfilenames(
            title="Select Archive Files to Extract",
            filetypes=[
                ("All Supported Archives", "*.zip;*.rar;*.7z;*.tar;*.tar.gz;*.tgz;*.tar.bz2;*.tar.xz;*.gz;*.bz2;*.xz"),
                ("RAR Archives", "*.rar"),
                ("ZIP Archives", "*.zip"),
                ("7-Zip Archives", "*.7z"),
                ("TAR / Compressed", "*.tar;*.tar.gz;*.tgz;*.tar.bz2;*.tar.xz"),
                ("All Files", "*.*"),
            ],
        )
        if files:
            added = 0
            for f in files:
                p = Path(f)
                if p not in self.selected_files and p.is_file():
                    self.selected_files.append(p)
                    added += 1
            self._refresh_files_tree()
            self.status_lbl.config(text=f"Added {added} archive(s). Total: {len(self.selected_files)}")

    def _add_folder_archives(self) -> None:
        folder = filedialog.askdirectory(title="Select Folder to Scan for Archives")
        if folder:
            count = 0
            for item in Path(folder).iterdir():
                if item.is_file() and is_archive_file(item) and item not in self.selected_files:
                    self.selected_files.append(item)
                    count += 1
            self._refresh_files_tree()
            self.status_lbl.config(text=f"Found {count} archive(s) in folder")

    def _clear_selected_files(self) -> None:
        self.selected_files.clear()
        self._refresh_files_tree()
        self.progress_var.set(0)
        self.progress_detail_lbl.config(text="Ready to extract.")
        self.status_lbl.config(text="List cleared.")
        self.time_badge.config(text="", relief="flat", bg=self.bg_color)

    def _refresh_files_tree(self) -> None:
        for item in self.files_tree.get_children():
            self.files_tree.delete(item)
        for p in self.selected_files:
            try:
                size_str = format_bytes(p.stat().st_size)
            except Exception:
                size_str = "Unknown"
            self.files_tree.insert("", "end", values=(p.name, size_str, str(p.parent), "Ready"))
        self.file_count_lbl.config(text=f"{len(self.selected_files)} archive(s) selected")

    def _get_extraction_options(self) -> ExtractionOptions:
        conflict_raw = self.opt_conflict.get()
        if "overwrite" in conflict_raw:
            conflict_mode = "overwrite"
        elif "skip" in conflict_raw:
            conflict_mode = "skip"
        else:
            conflict_mode = "rename"

        return ExtractionOptions(
            create_subfolder=self.opt_subfolder.get(),
            conflict_mode=conflict_mode,
            delete_after_extract=self.opt_delete.get(),
            filter_junk=self.opt_filter_junk.get(),
        )

    def _start_manual_extraction(self) -> None:
        if self._is_extracting:
            return
        if not self.selected_files:
            messagebox.showinfo("No Files", "Please select archive files to extract first.")
            return

        dest_dir = self.dedicated_folder_var.get().strip()
        if not dest_dir:
            messagebox.showwarning("No Destination", "Please choose a dedicated destination folder.")
            return

        self._save_current_settings()
        self._batch_start_time = time.time()
        self._is_extracting = True
        self.extract_btn.config(state="disabled")
        self.cancel_btn.config(state="normal")
        self.progress_var.set(0)
        self.time_badge.config(
            text="⏳ Extracting...",
            bg="#e8f5e9",
            fg=self.primary_color,
            relief="solid",
            bd=1,
        )

        threading.Thread(target=self._run_batch_extraction, daemon=True).start()

    def _run_batch_extraction(self) -> None:
        dest_dir = Path(self.dedicated_folder_var.get().strip())
        options = self._get_extraction_options()
        total_archives = len(self.selected_files)

        self._log_manual("INFO", f"Starting batch extraction: {total_archives} archive(s)")
        total_extracted_files = 0
        total_extracted_bytes = 0
        error_details: List[str] = []

        tree_items = list(self.files_tree.get_children())
        files_to_remove: List[Path] = []

        for idx, archive_p in enumerate(list(self.selected_files), 1):
            if not self._is_extracting:
                break

            self.root.after(
                0,
                lambda i=idx, t=total_archives, name=archive_p.name: self.status_lbl.config(
                    text=f"Extracting [{i}/{t}]: {name}"
                ),
            )

            # Check if file exists on disk
            if not archive_p.exists():
                err_msg = f"{archive_p.name}: File not found on disk (already extracted & deleted, or moved)"
                error_details.append(err_msg)
                self._log_manual("WARNING", err_msg)
                if idx - 1 < len(tree_items):
                    item_id = tree_items[idx - 1]
                    self.root.after(0, lambda id=item_id: self.files_tree.set(id, "status", "File Missing"))
                files_to_remove.append(archive_p)
                continue

            res = self.extractor.extract(archive_p, dest_dir, options)
            self.history_mgr.add_entry(
                archive_path=archive_p,
                destination_folder=str(res.destination),
                files_extracted=res.files_extracted,
                bytes_extracted=res.bytes_extracted,
                duration_seconds=res.duration_seconds,
                success=res.success,
                error_message="; ".join(res.errors) if res.errors else None,
            )

            total_extracted_files += res.files_extracted
            total_extracted_bytes += res.bytes_extracted

            # Update row status in treeview
            if idx - 1 < len(tree_items):
                item_id = tree_items[idx - 1]
                if res.success:
                    if options.delete_after_extract:
                        status_str = f"Done ({res.files_extracted} files, Deleted)"
                        files_to_remove.append(archive_p)
                    else:
                        status_str = f"Done ({res.files_extracted} files)"
                else:
                    status_str = "Failed"
                self.root.after(0, lambda id=item_id, s=status_str: self.files_tree.set(id, "status", s))

            if res.errors:
                for err in res.errors:
                    error_details.append(f"{archive_p.name}: {err}")

        # Clean up deleted files from memory so clicking Extract again won't try to re-extract missing files
        for rf in files_to_remove:
            if rf in self.selected_files:
                self.selected_files.remove(rf)

        self.root.after(0, self._on_batch_complete, total_extracted_files, total_extracted_bytes, error_details)

    def _on_batch_complete(self, total_files: int, total_bytes: int, error_details: List[str]) -> None:
        self._is_extracting = False
        self.extract_btn.config(state="normal")
        self.cancel_btn.config(state="disabled")
        self.progress_var.set(100)

        elapsed_sec = max(0.01, time.time() - getattr(self, "_batch_start_time", time.time()))
        if elapsed_sec < 1.0:
            time_display = f"{elapsed_sec:.2f}s"
        else:
            time_display = f"{elapsed_sec:.1f}s"

        self.time_badge.config(
            text=f"⏱️ Extracted in {time_display} ({total_files} files)",
            bg="#e8f5e9",
            fg=self.primary_color,
            relief="solid",
            bd=1,
        )

        self.progress_detail_lbl.config(text=f"Batch complete: {total_files} files unpacked in {time_display}.")
        self.status_lbl.config(text=f"Finished in {time_display}! Unpacked {total_files} files ({format_bytes(total_bytes)})")
        self._refresh_history_tree()

        msg = (
            f"Extraction Complete!\n\n"
            f"• Extracted: {total_files} files\n"
            f"• Time Taken: {time_display}\n"
            f"• Total Data: {format_bytes(total_bytes)}\n"
            f"• Destination: {self.dedicated_folder_var.get().strip()}\n"
        )
        if error_details:
            msg += f"\n⚠️ Warnings / Issues ({len(error_details)}):\n"
            for err in error_details[:3]:
                msg += f"• {err}\n"

        if total_files > 0:
            if messagebox.askyesno("Extraction Complete", f"{msg}\nWould you like to open the extraction folder now?"):
                open_in_file_manager(self.dedicated_folder_var.get().strip())
        else:
            if error_details:
                messagebox.showwarning("Extraction Issue", msg)
            else:
                messagebox.showinfo("Extraction Complete", msg)

    def _cancel_extraction(self) -> None:
        self._is_extracting = False
        self.extractor.cancel()
        self.status_lbl.config(text="Cancelling extraction...")
        self.time_badge.config(
            text="⏹ Cancelled",
            bg="#fee2e2",
            fg="#b91c1c",
            relief="solid",
            bd=1,
        )

    def _on_extract_progress(self, percent: float, current_item: str, index: int, total: int) -> None:
        def update():
            self.progress_var.set(percent)
            short_name = Path(current_item).name if current_item else ""
            self.progress_detail_lbl.config(text=f"[{index}/{total}] ({percent:.0f}%) {short_name}")
        self.root.after(0, update)

    def _on_extract_log(self, level: str, message: str) -> None:
        def update():
            self._log_manual(level, message)
        self.root.after(0, update)

    def _log_manual(self, level: str, message: str) -> None:
        timestamp = time.strftime("%H:%M:%S")
        self.log_text.insert("end", f"[{timestamp}] [{level}] {message}\n")
        self.log_text.see("end")

    # --- History Tree Operations ---

    def _refresh_history_tree(self) -> None:
        for item in self.history_tree.get_children():
            self.history_tree.delete(item)
        for entry in self.history_mgr.entries:
            self.history_tree.insert(
                "",
                "end",
                values=(
                    entry.timestamp,
                    entry.archive_name,
                    entry.destination_folder,
                    entry.files_extracted,
                    format_bytes(entry.bytes_extracted),
                    entry.status,
                ),
            )

    def _open_selected_history_folder(self) -> None:
        selected = self.history_tree.selection()
        if not selected:
            messagebox.showinfo("Select Entry", "Please select a row from the history table first.")
            return
        dest_folder = self.history_tree.item(selected[0])["values"][2]
        if dest_folder:
            open_in_file_manager(dest_folder)

    def _clear_history(self) -> None:
        if messagebox.askyesno("Clear History", "Are you sure you want to clear all extraction history?"):
            self.history_mgr.clear()
            self._refresh_history_tree()


# ==============================================================================
# CLI & Main Entry Point
# ==============================================================================

def run_gui() -> None:
    root = tk.Tk()
    app = AutoZipExtractorGUI(root)

    def on_closing():
        app._save_current_settings()
        root.destroy()

    root.protocol("WM_DELETE_WINDOW", on_closing)
    root.mainloop()


def run_cli_extract(args: Any) -> None:
    archive_paths = [Path(p) for p in args.extract]
    dest_dir = Path(args.dest) if args.dest else get_default_extracted_folder()

    options = ExtractionOptions(
        create_subfolder=args.subfolder,
        conflict_mode=args.conflict,
        delete_after_extract=args.delete_archive,
        filter_junk=not args.keep_junk,
    )

    extractor = ArchiveExtractor(
        log_callback=lambda lvl, msg: print(f"[{lvl}] {msg}"),
        progress_callback=lambda pct, item, idx, tot: print(f"  [{idx}/{tot}] {pct:.1f}% - {Path(item).name}"),
    )
    history = HistoryManager()

    print(f"\n⚡ Auto Zip Extractor v{VERSION}")
    print(f"Target Dedicated Folder: {dest_dir.resolve()}\n")

    for archive in archive_paths:
        if not archive.exists() or not is_archive_file(archive):
            print(f"Skipping: {archive}")
            continue

        res = extractor.extract(archive, dest_dir, options)
        history.add_entry(
            archive_path=archive,
            destination_folder=res.destination,
            files_extracted=res.files_extracted,
            bytes_extracted=res.bytes_extracted,
            duration_seconds=res.duration_seconds,
            success=res.success,
            error_message="; ".join(res.errors) if res.errors else None,
        )
        if res.success:
            print(f"✅ Done! Unpacked {res.files_extracted} files into: {res.destination}\n")
        else:
            print(f"❌ Failed: {res.errors}\n")


def main() -> None:
    import argparse

    parser = argparse.ArgumentParser(description="Auto Zip Extractor: Extract files to a dedicated folder.")
    parser.add_argument("--gui", action="store_true", help="Launch graphical user interface.")
    parser.add_argument("-e", "--extract", nargs="+", metavar="ARCHIVE", help="Extract archive files.")
    parser.add_argument("-d", "--dest", metavar="FOLDER", help="Dedicated destination folder.")
    parser.add_argument("--subfolder", action="store_true", help="Create subfolder for each archive (default: extract directly).")
    parser.add_argument("--conflict", choices=["rename", "overwrite", "skip"], default="rename", help="Conflict mode.")
    parser.add_argument("--delete-archive", action="store_true", help="Delete archive after extraction.")
    parser.add_argument("--keep-junk", action="store_true", help="Keep system junk files.")
    parser.add_argument("-v", "--version", action="version", version=f"Auto Zip Extractor {VERSION}")

    args = parser.parse_args()

    if args.extract:
        run_cli_extract(args)
    else:
        run_gui()


if __name__ == "__main__":
    main()
