# exiftree

`exiftree.sh` builds a clean, chronological directory tree for photos and videos by reading their metadata and copying them into date-based folders. It scans a source directory for common image/video formats, extracts the best available capture timestamp, and copies each file into a `YYYY/MM/DD` folder under the destination with a `YYYYMMDD_HHMMSS`-based filename. When metadata is missing, it falls back to the file modification time. It also keeps a SHA-256 database to skip duplicates on subsequent runs. Optional flags let you use month names or day names (English or French) in the directory structure.

Key behaviors:
- Accepts a source directory and a destination directory.
- Detects images and videos via a case-insensitive extension list (JPEG, PNG, HEIC, TIFF, CR2, MP4, MOV, MKV, etc.).
- Uses `exiftool` to read the first available timestamp from `DateTimeOriginal`, `MediaCreateDate`, `CreateDate`, or `TrackCreateDate`.
- Falls back to file mtime if no metadata date is present.
- Creates destination paths like `DEST/YYYY/MM/DD/YYYYMMDD_HHMMSS.ext` by default.
- Can optionally create month folders with names (e.g. `January`) and day folders like `Monday 03 March` in English or French.
- If a filename already exists, appends `-1`, `-2`, etc.
- Deduplicates using SHA-256 and stores the hashes in `DEST/.imported_sha256.txt`.
- Converts Canon CR2 files to JPEG via `darktable-cli`, preserves tags, and imports the JPEG.

## Installation (Linux)

Install dependencies:

```bash
sudo apt-get update
sudo apt-get install -y exiftool darktable
```

Make the script executable:

```bash
chmod +x ./exiftree.sh
```

(Optional) Add it to your PATH:

```bash
sudo ln -s "$(pwd)/exiftree.sh" /usr/local/bin/exiftree
```

## Usage

```bash
./exiftree.sh [options] /path/to/source /path/to/destination
```

Example:

```bash
./exiftree.sh ~/Downloads/Takeout ~/Pictures/Library
```

Use month or day names (English by default):

```bash
./exiftree.sh --month-name --day-name --lang en ~/Downloads/Takeout ~/Pictures/Library
```

Use French names for month/day folders:

```bash
./exiftree.sh --month-name --day-name --lang fr ~/Downloads/Takeout ~/Pictures/Library
```

This will populate `~/Pictures/Library` with a date-based hierarchy and print a summary of how many files were imported, skipped as duplicates, failed conversion, or lacked EXIF data.
