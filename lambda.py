import sys
from pathlib import Path

if len(sys.argv) < 2:
    print("Usage: python lambda.py <input_file>")
    sys.exit(1)

INPUT_FILE = sys.argv[1]
OUTPUT_DIR = Path("extracts")

if not Path(INPUT_FILE).exists():
    print(f"❌ Error: File '{INPUT_FILE}' not found!")
    sys.exit(1)

OUTPUT_DIR.mkdir(exist_ok=True)

with open(INPUT_FILE, "r", encoding="utf-8") as f:
    lines = f.readlines()

# The pipe-delimited structure is:
# |file_name|mac_id|phase|record_type|record_sequence|claim_sequence|line_sequence|record_content|
# So after split: [0]=empty, [1]=file_name, ..., [8]=record_content, [9]=empty

current_file = None
file_handle = None
record_count = 0
total_files = 0

# Skip header (line 0) and separator (line 1)
for line_num, line in enumerate(lines[2:], start=3):
    if not line.strip():
        continue

    # Split by pipe - this gives us 10 parts (including leading/trailing empties)
    parts = line.rstrip("\n").split("|")

    # We need at least 9 parts to have record_content at index 8
    if len(parts) < 9:
        print(f"⚠️  Line {line_num}: only {len(parts)} parts")
        continue

    # Extract fields - record_content is ALWAYS at index 8
    file_name = parts[1].strip()
    record_type = parts[4].strip()
    # Preserve exact record content - DO NOT strip spaces (they're part of fixed-width format)
    record_content = parts[8].rstrip("\n")

    if not file_name or not record_content:
        print(f"⚠️  Line {line_num}: empty file_name or record_content")
        continue

    # Open new file when file_name changes
    if file_name != current_file:
        if file_handle:
            file_handle.close()
            print(f"✅ {current_file}: {record_count} records")

        output_path = OUTPUT_DIR / file_name
        file_handle = open(output_path, "w", encoding="utf-8")
        current_file = file_name
        record_count = 0
        total_files += 1

    record_length_limits = {
        "FILE_HEADER": 41,
        "CLAIM_HEADER": 5651,
        "CLAIM_LINE": 2332,
        "FILE_TRAILER": 44,
    }
    max_length = record_length_limits.get(record_type)
    if max_length is not None and len(record_content) > max_length:
        record_content = record_content[:max_length]

    # Write record - all internal spaces preserved!
    file_handle.write(record_content + "\n")
    record_count += 1

if file_handle:
    file_handle.close()
    print(f"✅ {current_file}: {record_count} records")

print(f"\n🎉 Generated {total_files} files in {OUTPUT_DIR}/")
