#!/usr/bin/env Rscript
#
# Summarize spot percentages for all top 10 SV modes
# Ranked by mean percentage across 4 samples
#

library(data.table)
library(dplyr)

cat("================================================================================\n")
cat("SV Mode Spot Percentages Summary (Top 5 SVs)\n")
cat("================================================================================\n\n")

# ============================================================================
# LOAD DATA
# ============================================================================

cat("Loading classification results...\n")
sg_assignments <- fread("local/outputs/GSE193460_cohort_isg_analysis/sg_sv_assignments_top5.txt")

cat(sprintf("  Total SG pairs: %d\n", nrow(sg_assignments)))
cat(sprintf("  SV modes: %d\n\n", length(unique(sg_assignments$SV_Signed))))

# ============================================================================
# LOAD SPATIAL DATA
# ============================================================================

cat("Loading spatial coordinates...\n")

sample_info <- data.table(
  SampleID = c("KP_1", "KP_2", "KP_3", "KP_4"),
  sample_dir = c(
    "GSE193460_GSM5808054_KP_1_native_prod_20260214_213405",
    "GSE193460_GSM5808055_KP_2_native_prod_20260214_220319",
    "outputs_native_prod_20260214_230807",
    "outputs_native_prod_20260214_230817"
  )
)

all_leaves_list <- list()

for (i in 1:nrow(sample_info)) {
  if (grepl("^outputs_native", sample_info$sample_dir[i])) {
    leaves_file <- file.path("local", sample_info$sample_dir[i], 
                             "optimal", "allnodes_leaves.tsv")
  } else {
    leaves_file <- file.path("local/outputs", sample_info$sample_dir[i], 
                             "optimal", "allnodes_leaves.tsv")
  }
  
  if (file.exists(leaves_file)) {
    leaves <- fread(leaves_file)
    leaves[, SampleID := sample_info$SampleID[i]]
    all_leaves_list[[sample_info$SampleID[i]]] <- leaves
  }
}

all_leaves <- rbindlist(all_leaves_list, fill = TRUE)

# ============================================================================
# MAP TO SPOTS
# ============================================================================

cat("Mapping SG assignments to spots...\n")

# Merge spatial data with SG assignments
sg_assignments_subset <- sg_assignments %>%
  select(SampleID, Node, SV_Signed)

spatial_data <- merge(
  all_leaves, 
  sg_assignments_subset,
  by = c("SampleID", "Node"),
  all.x = TRUE
)

spatial_data <- as.data.table(spatial_data)
spatial_data[is.na(SV_Signed), SV_Signed := "Unassigned"]

# Deduplicate to unique barcodes
# If a barcode belongs to multiple nodes with different SV assignments,
# prioritize the assignment (any assignment > Unassigned)
spatial_data_unique <- spatial_data %>%
  group_by(SampleID, Leaf, array_row, array_col) %>%
  summarise(
    SV_Signed = {
      assigned <- SV_Signed[SV_Signed != "Unassigned"]
      if (length(assigned) > 0) assigned[1] else "Unassigned"
    },
    .groups = "drop"
  )

spatial_data_unique <- as.data.table(spatial_data_unique)

cat(sprintf("  Unique spots: %d\n\n", nrow(spatial_data_unique)))

# ============================================================================
# CALCULATE PERCENTAGES BY SV MODE AND SAMPLE
# ============================================================================

cat("Calculating percentages by SV mode and sample...\n\n")

# Get total spots per sample
sample_totals <- spatial_data_unique %>%
  group_by(SampleID) %>%
  summarise(Total_Spots = n(), .groups = "drop")

# Get counts per SV mode per sample
sv_mode_counts <- spatial_data_unique %>%
  filter(SV_Signed != "Unassigned") %>%
  group_by(SampleID, SV_Signed) %>%
  summarise(N_Spots = n(), .groups = "drop") %>%
  left_join(sample_totals, by = "SampleID") %>%
  mutate(Pct = 100 * N_Spots / Total_Spots)

# Calculate mean percentage across samples for each SV mode
sv_mode_summary <- sv_mode_counts %>%
  group_by(SV_Signed) %>%
  summarise(
    Mean_Pct = mean(Pct),
    SD_Pct = sd(Pct),
    Total_Spots = sum(N_Spots),
    .groups = "drop"
  ) %>%
  arrange(desc(Mean_Pct))

# ============================================================================
# DISPLAY RESULTS
# ============================================================================

cat("================================================================================\n")
cat("SV MODE RANKINGS (by mean % of spots across 4 samples)\n")
cat("================================================================================\n\n")

cat(sprintf("%-12s %12s %12s %12s\n", "SV_Mode", "Mean_%", "SD_%", "Total_Spots"))
cat(strrep("-", 50), "\n")

for (i in 1:nrow(sv_mode_summary)) {
  cat(sprintf("%-12s %11.2f%% %11.2f%% %12d\n",
              sv_mode_summary$SV_Signed[i],
              sv_mode_summary$Mean_Pct[i],
              sv_mode_summary$SD_Pct[i],
              sv_mode_summary$Total_Spots[i]))
}

cat("\n")

# ============================================================================
# DETAILED BREAKDOWN BY SAMPLE
# ============================================================================

cat("================================================================================\n")
cat("DETAILED BREAKDOWN BY SAMPLE\n")
cat("================================================================================\n\n")

# Pivot to wide format for easier viewing
sv_mode_wide <- sv_mode_counts %>%
  select(SampleID, SV_Signed, Pct) %>%
  tidyr::pivot_wider(names_from = SampleID, values_from = Pct, values_fill = 0) %>%
  arrange(desc((KP_1 + KP_2 + KP_3 + KP_4) / 4))

print(sv_mode_wide, n = Inf)

# ============================================================================
# SAMPLE TOTALS
# ============================================================================

cat("\n\n")
cat("================================================================================\n")
cat("SAMPLE TOTALS\n")
cat("================================================================================\n\n")

cat(sprintf("%-10s %12s\n", "Sample", "Total_Spots"))
cat(strrep("-", 25), "\n")
for (i in 1:nrow(sample_totals)) {
  cat(sprintf("%-10s %12d\n", sample_totals$SampleID[i], sample_totals$Total_Spots[i]))
}
cat(sprintf("%-10s %12d\n", "TOTAL", sum(sample_totals$Total_Spots)))

cat("\n")
cat("================================================================================\n")
