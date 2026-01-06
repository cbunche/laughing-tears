#!/usr/bin/env python3
"""
Validate padding and positional location of fields in SQL script
"""

import re
import sys

def validate_sql_fields(sql_file):
    """Validate field padding and positions in SQL file"""
    
    errors = []
    warnings = []
    
    with open(sql_file, 'r', encoding='utf-8') as f:
        content = f.read()
    
    fields = []
    
    # Pattern 1: Multi-line COALESCE/RPAD/LPAD blocks ending with comment
    # Matches blocks like:
    #   RPAD(
    #       COALESCE(...),
    #       25,
    #       ' '
    #   ) || -- 4911-4935: FIELD_NAME
    pattern1 = r'(RPAD|LPAD)\s*\([^)]*?,\s*(\d+)\s*,\s*[\'"](.)[\'\"]\s*\)\s*\|\|\s*--\s*(\d+)-(\d+):\s*(.+?)(?:\n|$)'
    
    # Pattern 2: Simple single-line format
    # RPAD('', 25, ' ') || -- 4911-4935: FIELD_NAME
    pattern2 = r'(RPAD|LPAD)\s*\(\s*[\'"][\'"]?\s*,\s*(\d+)\s*,\s*[\'"](.)[\'\"]\s*\)\s*\|\|\s*--\s*(\d+)-(\d+):\s*(.+?)(?:\n|$)'
    
    # Try both patterns
    for pattern in [pattern1, pattern2]:
        for match in re.finditer(pattern, content, re.MULTILINE | re.DOTALL):
            pad_type = match.group(1)
            pad_length = int(match.group(2))
            pad_char = match.group(3)
            start_pos = int(match.group(4))
            end_pos = int(match.group(5))
            field_name = match.group(6).strip()
            
            # Calculate expected length from positions
            expected_length = end_pos - start_pos + 1
            
            # Calculate approximate line number
            line_num = content[:match.start()].count('\n') + 1
            
            fields.append({
                'line': line_num,
                'pad_type': pad_type,
                'pad_length': pad_length,
                'pad_char': pad_char,
                'start': start_pos,
                'end': end_pos,
                'expected_length': expected_length,
                'field_name': field_name
            })
    
    # Remove duplicates (in case both patterns matched same field)
    seen = set()
    unique_fields = []
    for field in fields:
        key = (field['start'], field['end'], field['field_name'])
        if key not in seen:
            seen.add(key)
            unique_fields.append(field)
    
    fields = sorted(unique_fields, key=lambda f: f['start'])
    
    print(f"Found {len(fields)} fields to validate")
    
    # Debug: If no fields found, show sample of file content
    if len(fields) == 0:
        print("\n⚠️  No fields found. Showing first 20 lines of file for debugging:\n")
        print("="*100)
        lines = content.split('\n')[:20]
        for i, line in enumerate(lines, 1):
            print(f"{i:3d}: {line[:97]}")
        print("="*100)
        print("\nExpected format: RPAD(..., LENGTH, 'CHAR') || -- START-END: FIELD_NAME")
        print("If your format is different, please share a sample line.\n")
        return True
    
    print()
    
    # Validate each field
    for i, field in enumerate(fields):
        # Check 1: Padding length matches position range
        if field['pad_length'] != field['expected_length']:
            errors.append({
                'line': field['line'],
                'type': 'LENGTH_MISMATCH',
                'field': field['field_name'],
                'position': f"{field['start']}-{field['end']}",
                'message': f"Padding is {field['pad_length']} chars but position range is {field['expected_length']} chars",
                'severity': 'ERROR'
            })
        
        # Check 2: Contiguous positions (no gaps)
        if i > 0:
            prev_field = fields[i-1]
            if field['start'] != prev_field['end'] + 1:
                gap_size = field['start'] - prev_field['end'] - 1
                if gap_size > 0:
                    errors.append({
                        'line': field['line'],
                        'type': 'GAP',
                        'field': field['field_name'],
                        'position': f"{prev_field['end']+1}-{field['start']-1}",
                        'message': f"Gap of {gap_size} chars between {prev_field['field_name']} and {field['field_name']}",
                        'severity': 'ERROR'
                    })
                elif gap_size < 0:
                    errors.append({
                        'line': field['line'],
                        'type': 'OVERLAP',
                        'field': field['field_name'],
                        'position': f"{field['start']}-{prev_field['end']}",
                        'message': f"Overlap of {abs(gap_size)} chars with previous field {prev_field['field_name']}",
                        'severity': 'ERROR'
                    })
        
        # Check 3: Padding type matches field type (warning only)
        if 'EOMB-AMT' in field['field_name'] or 'DATE' in field['field_name'] or 'NUM' in field['field_name']:
            if field['pad_type'] != 'LPAD' or field['pad_char'] != '0':
                warnings.append({
                    'line': field['line'],
                    'type': 'PADDING_TYPE',
                    'field': field['field_name'],
                    'position': f"{field['start']}-{field['end']}",
                    'message': f"Numeric field using {field['pad_type']} with '{field['pad_char']}' (expected LPAD with '0')",
                    'severity': 'WARNING'
                })
    
    # Print results
    if errors:
        print(f"❌ ERRORS FOUND: {len(errors)}\n")
        print("=" * 100)
        for err in errors:
            print(f"Line {err['line']:4d} | {err['type']:15s} | Pos {err['position']:12s} | {err['field']}")
            print(f"         | {err['message']}")
            print("-" * 100)
    else:
        print("✅ No errors found - all padding and positions are correct!\n")
    
    if warnings:
        print(f"\n⚠️  WARNINGS: {len(warnings)}\n")
        print("=" * 100)
        for warn in warnings:
            print(f"Line {warn['line']:4d} | {warn['type']:15s} | Pos {warn['position']:12s} | {warn['field']}")
            print(f"         | {warn['message']}")
            print("-" * 100)
    
    # Summary
    print(f"\n{'='*100}")
    print(f"SUMMARY:")
    print(f"  Total fields validated: {len(fields)}")
    print(f"  Errors: {len(errors)}")
    print(f"  Warnings: {len(warnings)}")
    
    if fields:
        print(f"  Position range: {fields[0]['start']} to {fields[-1]['end']}")
        total_length = sum(f['pad_length'] for f in fields)
        expected_total = fields[-1]['end'] - fields[0]['start'] + 1
        print(f"  Total length (sum of padding): {total_length}")
        print(f"  Expected total length: {expected_total}")
        if total_length != expected_total:
            print(f"  ⚠️  Length discrepancy: {total_length - expected_total:+d} chars")
    print(f"{'='*100}\n")
    
    return len(errors) == 0

if __name__ == '__main__':
    if len(sys.argv) != 2:
        print("Usage: python validate_sql_fields.py <sql_file>")
        sys.exit(1)
    
    sql_file = sys.argv[1]
    
    try:
        success = validate_sql_fields(sql_file)
        sys.exit(0 if success else 1)
    except FileNotFoundError:
        print(f"Error: File '{sql_file}' not found")
        sys.exit(1)