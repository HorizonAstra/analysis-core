# SLURM Job Templates

This directory contains SLURM job submission templates for running TumorSPACE_AWS analyses on HPC clusters.

## Available Templates

### example_job.sbatch
Basic example demonstrating:
- Container execution through Singularity
- Resource allocation (8 CPUs, 32GB RAM, 6 hours)
- Input/output directory setup
- Error handling and logging

**Usage:**
```bash
sbatch benchmarking/slurm/example_job.sbatch
```

## Customizing Jobs

### Resource Requirements

Adjust based on your dataset size:

**Small datasets (<1000 spots):**
```bash
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --time=02:00:00
```

**Medium datasets (1000-5000 spots):**
```bash
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --time=06:00:00
```

**Large datasets (>5000 spots):**
```bash
#SBATCH --cpus-per-task=16
#SBATCH --mem=64G
#SBATCH --time=12:00:00
```

### Account and Partition

Update these lines for your HPC setup:
```bash
#SBATCH --account=YOUR_ACCOUNT
#SBATCH --partition=YOUR_PARTITION
```

### Monitoring Jobs

```bash
# Check job status
squeue -u $USER

# View job details
scontrol show job JOB_ID

# Cancel job
scancel JOB_ID

# Check job output
tail -f logs/tumorspace_example_JOB_ID.out
```

## Best Practices

1. **Test with small data first**: Use the benchmark dataset to validate your setup
2. **Check resource usage**: Review job statistics to optimize resource requests
3. **Use job arrays**: For processing multiple datasets in parallel
4. **Save checkpoints**: For long-running analyses
5. **Document parameters**: Keep track of analysis parameters in config files

## Creating New Templates

When creating new job templates:

1. Copy example_job.sbatch as a starting point
2. Update resource requirements
3. Add specific analysis commands
4. Test with benchmark data
5. Document the template purpose

## Troubleshooting

### Job fails immediately
- Check container path is correct
- Verify input data exists
- Review error logs in `logs/`

### Out of memory errors
- Increase `--mem` parameter
- Check dataset size vs available memory

### Time limit exceeded
- Increase `--time` parameter
- Consider breaking analysis into stages

## Additional Resources

- SLURM documentation: https://slurm.schedmd.com/
- Midway3 user guide: https://rcc.uchicago.edu/docs/
- Contact: Vivek Behera (beheravivek@gmail.com)
