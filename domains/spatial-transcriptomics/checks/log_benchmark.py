#!/usr/bin/env python3
"""
TumorSPACE Benchmark Logger
Collects and aggregates SLURM job statistics from sacct
"""

import subprocess
import json
import csv
import os
from datetime import datetime
from pathlib import Path
import argparse

def get_dataset_info(input_dir):
    """Extract dataset name and spot count from barcodes file"""
    dataset_name = Path(input_dir).name
    barcodes_file = Path(input_dir) / "barcodes.txt"
    
    if barcodes_file.exists():
        with open(barcodes_file) as f:
            spot_count = sum(1 for _ in f)
    else:
        spot_count = "unknown"
    
    return dataset_name, spot_count

def get_git_commit():
    """Get current git commit hash"""
    try:
        result = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            check=True
        )
        return result.stdout.strip()[:8]  # Short hash
    except:
        return "unknown"

def parse_sacct_output(job_id):
    """Query SLURM accounting data for job statistics"""
    cmd = [
        "sacct",
        "-j", str(job_id),
        "--format=JobID,JobName,State,Elapsed,TotalCPU,MaxRSS,AllocCPUS,AllocMem",
        "--parsable2",
        "--noheader"
    ]
    
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        lines = result.stdout.strip().split('\n')
        
        tasks = []
        for line in lines:
            if not line or '.batch' in line or '.extern' in line:
                continue
                
            fields = line.split('|')
            if len(fields) >= 8:
                tasks.append({
                    'job_id': fields[0],
                    'job_name': fields[1],
                    'state': fields[2],
                    'elapsed': fields[3],
                    'cpu_time': fields[4],
                    'max_rss': fields[5],
                    'alloc_cpus': fields[6],
                    'alloc_mem': fields[7]
                })
        
        return tasks
    except subprocess.CalledProcessError as e:
        print(f"Error querying sacct: {e}")
        return []

def aggregate_stats(tasks):
    """Aggregate statistics across all tasks"""
    if not tasks:
        return {}
    
    completed = [t for t in tasks if t['state'] == 'COMPLETED']
    failed = [t for t in tasks if t['state'] in ['FAILED', 'TIMEOUT', 'CANCELLED']]
    
    def parse_time(timestr):
        """Parse SLURM time format (DD-HH:MM:SS or HH:MM:SS) to seconds"""
        if not timestr or timestr == '':
            return 0
        
        parts = timestr.split('-')
        if len(parts) == 2:
            days = int(parts[0])
            time_parts = parts[1].split(':')
        else:
            days = 0
            time_parts = parts[0].split(':')
        
        hours, mins, secs = map(int, time_parts)
        return days * 86400 + hours * 3600 + mins * 60 + secs
    
    def parse_memory(memstr):
        """Parse memory string (e.g., '1234K', '56M', '7G') to MB"""
        if not memstr or memstr == '':
            return 0
        
        memstr = memstr.strip()
        if memstr.endswith('K'):
            return float(memstr[:-1]) / 1024
        elif memstr.endswith('M'):
            return float(memstr[:-1])
        elif memstr.endswith('G'):
            return float(memstr[:-1]) * 1024
        else:
            return float(memstr) / (1024 * 1024)  # Assume bytes
    
    # Calculate statistics
    elapsed_times = [parse_time(t['elapsed']) for t in completed]
    cpu_times = [parse_time(t['cpu_time']) for t in completed]
    max_rss_values = [parse_memory(t['max_rss']) for t in completed]
    
    stats = {
        'total_tasks': len(tasks),
        'completed': len(completed),
        'failed': len(failed),
        'success_rate': f"{len(completed)/len(tasks)*100:.1f}%" if tasks else "0%",
        'avg_elapsed_sec': sum(elapsed_times) / len(elapsed_times) if elapsed_times else 0,
        'max_elapsed_sec': max(elapsed_times) if elapsed_times else 0,
        'total_cpu_hours': sum(cpu_times) / 3600 if cpu_times else 0,
        'avg_memory_mb': sum(max_rss_values) / len(max_rss_values) if max_rss_values else 0,
        'max_memory_mb': max(max_rss_values) if max_rss_values else 0
    }
    
    return stats

def log_benchmark(job_id, execution_mode, dataset, input_dir, output_file="benchmarks/runtime_stats.csv"):
    """Log benchmark results to CSV file"""
    
    # Get metadata
    commit_hash = get_git_commit()
    dataset_name, spot_count = get_dataset_info(input_dir)
    run_date = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    
    # Query SLURM stats
    print(f"Querying SLURM accounting for job {job_id}...")
    tasks = parse_sacct_output(job_id)
    stats = aggregate_stats(tasks)
    
    if not stats:
        print("Warning: No statistics available yet. Job may still be running.")
        return
    
    # Prepare record
    record = {
        'run_date': run_date,
        'commit_hash': commit_hash,
        'execution_mode': execution_mode,
        'dataset': dataset_name,
        'spot_count': spot_count,
        'job_id': job_id,
        'total_tasks': stats.get('total_tasks', 0),
        'completed_tasks': stats.get('completed', 0),
        'failed_tasks': stats.get('failed', 0),
        'success_rate': stats.get('success_rate', '0%'),
        'avg_runtime_sec': f"{stats.get('avg_elapsed_sec', 0):.1f}",
        'max_runtime_sec': f"{stats.get('max_elapsed_sec', 0):.1f}",
        'total_cpu_hours': f"{stats.get('total_cpu_hours', 0):.2f}",
        'avg_memory_mb': f"{stats.get('avg_memory_mb', 0):.1f}",
        'max_memory_mb': f"{stats.get('max_memory_mb', 0):.1f}"
    }
    
    # Write to CSV
    os.makedirs(os.path.dirname(output_file), exist_ok=True)
    file_exists = os.path.isfile(output_file)
    
    with open(output_file, 'a', newline='') as f:
        writer = csv.DictWriter(f, fieldnames=record.keys())
        if not file_exists:
            writer.writeheader()
        writer.writerow(record)
    
    print(f"\n{'='*60}")
    print(f"Benchmark Results for Job {job_id}")
    print(f"{'='*60}")
    for key, value in record.items():
        print(f"  {key:20s}: {value}")
    print(f"{'='*60}")
    print(f"\nResults appended to: {output_file}")

def main():
    parser = argparse.ArgumentParser(description="Log TumorSPACE benchmark statistics")
    parser.add_argument("--job-id", required=True, help="SLURM job ID")
    parser.add_argument("--mode", required=True, choices=['container', 'direct'], 
                       help="Execution mode")
    parser.add_argument("--dataset", required=True, help="Dataset name")
    parser.add_argument("--input-dir", required=True, help="Path to dataset input directory")
    parser.add_argument("--output", default="benchmarks/runtime_stats.csv",
                       help="Output CSV file (default: benchmarks/runtime_stats.csv)")
    
    args = parser.parse_args()
    
    log_benchmark(
        job_id=args.job_id,
        execution_mode=args.mode,
        dataset=args.dataset,
        input_dir=args.input_dir,
        output_file=args.output
    )

if __name__ == "__main__":
    main()
