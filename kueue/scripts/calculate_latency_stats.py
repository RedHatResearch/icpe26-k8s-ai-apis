#!/usr/bin/env python3
"""
Script to parse JSON files and calculate comprehensive latency statistics.
Converts milliseconds to seconds and aggregates data from multiple files.
"""

import json
import pandas as pd
import sys
import numpy as np


def load_data_from_files(json_file_paths):
    """
    Load data from multiple JSON files and combine into a single DataFrame.

    Args:
        json_file_paths: List of paths to JSON files containing job latency measurements

    Returns:
        Combined DataFrame with all data from all files
    """
    all_data = []

    for json_file_path in json_file_paths:
        try:
            with open(json_file_path, 'r') as f:
                data = json.load(f)
                all_data.extend(data)
            print(f"✓ Loaded {len(data)} records from: {json_file_path}")
        except FileNotFoundError:
            print(f"✗ Error: File '{json_file_path}' not found. Skipping.")
        except json.JSONDecodeError:
            print(f"✗ Error: Invalid JSON format in '{json_file_path}'. Skipping.")
        except Exception as e:
            print(f"✗ Error loading '{json_file_path}': {e}. Skipping.")

    if not all_data:
        raise ValueError("No data could be loaded from any of the provided files.")

    return pd.DataFrame(all_data)


def calculate_latency_stats(json_file_paths):
    """
    Parse JSON files and calculate comprehensive latency statistics.

    Args:
        json_file_paths: List of paths to JSON files containing job latency measurements
    """
    # Load and combine data from all files
    print("\n" + "="*70)
    print("Loading Data Files")
    print("="*70)
    df = load_data_from_files(json_file_paths)

    # Convert milliseconds to seconds
    df['startTimeLatency_sec'] = df['startTimeLatency'] / 1000.0
    df['completionLatency_sec'] = df['completionLatency'] / 1000.0

    # Calculate statistics for start time latency
    start_stats = {
        'mean': df['startTimeLatency_sec'].mean(),
        'median': df['startTimeLatency_sec'].median(),
        'p50': df['startTimeLatency_sec'].quantile(0.50),
        'p95': df['startTimeLatency_sec'].quantile(0.95),
        'p99': df['startTimeLatency_sec'].quantile(0.99),
        'max': df['startTimeLatency_sec'].max(),
        'min': df['startTimeLatency_sec'].min(),
        'std': df['startTimeLatency_sec'].std()
    }

    # Calculate statistics for completion latency
    completion_stats = {
        'mean': df['completionLatency_sec'].mean(),
        'median': df['completionLatency_sec'].median(),
        'p50': df['completionLatency_sec'].quantile(0.50),
        'p95': df['completionLatency_sec'].quantile(0.95),
        'p99': df['completionLatency_sec'].quantile(0.99),
        'max': df['completionLatency_sec'].max(),
        'min': df['completionLatency_sec'].min(),
        'std': df['completionLatency_sec'].std()
    }

    # Print results
    print("\n" + "="*70)
    print(f"Analysis Summary")
    print("="*70)
    print(f"Total files analyzed:  {len(json_file_paths)}")
    print(f"Total number of jobs:  {len(df)}")

    print("\n" + "="*70)
    print("Start Time Latency Statistics (seconds):")
    print("="*70)
    print(f"Mean (Average):        {start_stats['mean']:>10.2f} s")
    print(f"Median (P50):          {start_stats['median']:>10.2f} s")
    print(f"P95:                   {start_stats['p95']:>10.2f} s")
    print(f"P99:                   {start_stats['p99']:>10.2f} s")
    print(f"Max:                   {start_stats['max']:>10.2f} s")
    print(f"Min:                   {start_stats['min']:>10.2f} s")
    print(f"Standard Deviation:    {start_stats['std']:>10.2f} s")

    print("\n" + "="*70)
    print("Completion Latency Statistics (seconds):")
    print("="*70)
    print(f"Mean (Average):        {completion_stats['mean']:>10.2f} s")
    print(f"Median (P50):          {completion_stats['median']:>10.2f} s")
    print(f"P95:                   {completion_stats['p95']:>10.2f} s")
    print(f"P99:                   {completion_stats['p99']:>10.2f} s")
    print(f"Max:                   {completion_stats['max']:>10.2f} s")
    print(f"Min:                   {completion_stats['min']:>10.2f} s")
    print(f"Standard Deviation:    {completion_stats['std']:>10.2f} s")

    return {
        'start_time_stats': start_stats,
        'completion_stats': completion_stats,
        'total_jobs': len(df),
        'total_files': len(json_file_paths)
    }


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python calculate_latency_stats.py <json_file_path> [<json_file_path2> ...]")
        print("\nExamples:")
        print("  # Single file:")
        print("  python calculate_latency_stats.py whisper-results-8/jobLatencyMeasurement-whisper-scale.json")
        print("\n  # Multiple files:")
        print("  python calculate_latency_stats.py whisper-results-*/jobLatencyMeasurement-whisper-scale.json")
        print("  python calculate_latency_stats.py file1.json file2.json file3.json")
        sys.exit(1)

    json_file_paths = sys.argv[1:]

    try:
        stats = calculate_latency_stats(json_file_paths)
    except ValueError as e:
        print(f"\nError: {e}")
        sys.exit(1)
    except KeyError as e:
        print(f"\nError: Expected field {e} not found in JSON data.")
        sys.exit(1)
    except Exception as e:
        print(f"\nUnexpected error: {e}")
        sys.exit(1)
