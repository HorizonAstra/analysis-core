args <- commandArgs(trailingOnly = TRUE)
cat("Received args:", paste(args, collapse = " "), "\n")

if (length(args) == 1) {
  # Legacy mode: single directory for both input and output
  tree_dir <- args[1]
  output_dir <- args[1]
} else if (length(args) == 2) {
  # New mode: separate output and input directories
  output_dir <- args[1]
  tree_dir <- args[2]  # Input tree directory (step4)
} else {
  stop("Usage: Rscript SG_compute.R <output_dir> <input_tree_dir> OR Rscript SG_compute.R <combined_dir>")
}

cat("Input tree dir:", tree_dir, "\n")
cat("Output dir:", output_dir, "\n")

# Create output directory if it doesn't exist
dir.create(output_dir, showWarnings = FALSE, recursive = TRUE)

# Load required packages
cat("Loading required R packages...\n")

required_packages <- c("dplyr","data.table","ape","phangorn")
for (pkg in required_packages) {
    if (!require(pkg, character.only = TRUE, quietly = TRUE)) {
        stop(paste("Required package not available:", pkg))
    }
}
cat("All packages loaded successfully\n")

# Required functions
tree_node_relabel <- function(tree){
  num_leaves = length(tree$tip.label)
  tree$node.label <- c((num_leaves + 1):(num_leaves + tree$Nnode))
  tree
}

node_info_extract <- function(tree){
  num_leaves = length(tree$tip.label)
  node_info <- NULL
  for (node in tree$node.label){
      if ((as.numeric(node) %% 100) == 0){print(paste0("Extracting info for node: ",node))}
      n_leafs = length(Descendants(tree, node, type = "tips")[[1]])
      parent = Ancestors(tree, node, type = c("parent"))
      x = Siblings(tree, node)
      sibling = x[x>num_leaves]
      num_sibling = length(sibling)
      if (length(sibling) == 0){sibling <- NA}
      node_info <- rbindlist(list(node_info,data.frame(Node = node,N_Leafs = n_leafs,Parent = parent, Sibling = sibling, Num_Siblings = num_sibling)))
  }
  node_info
}

node_compare_extract <- function(tree,node_info,leaf_min = 10){
    num_leaves = length(tree$tip.label)
    node_compare_list <- NULL
    node_compare_leaves <- NULL
    node_skip_list <- NULL
    for (node in tree$node.label){
        if ((node %% 100) == 0){print(paste0("Extracting info for node: ",node))}
        if (!(node %in% node_skip_list)){
        n_leafs = node_info[Node == node]$N_Leafs
        parent = node_info[Node == node]$Parent
        x = c(Siblings(tree, node),node)
        # Find most populous daughter node
        sibling_nodes = x[x>num_leaves]
        sibling_leaves = x[x<=num_leaves]
        dom_node = arrange(unique(node_info[Node %in% sibling_nodes],by="Node"),-N_Leafs)$Node[1]
        sibling_node_leaves = sum(unique(node_info[Node %in% sibling_nodes],by="Node")[Node != dom_node]$N_Leafs)
        total_sibling_leaves = length(sibling_leaves)+sibling_node_leaves
        if ((node_info[Node == dom_node]$N_Leafs[1] >= leaf_min)&&(total_sibling_leaves >= leaf_min)){ 
            node_compare_list <- rbindlist(list(node_compare_list,data.frame(Parent = node_info[Node == dom_node]$Parent[1], Node = dom_node, Node_Leaves = node_info[Node == dom_node]$N_Leafs[1], Sibling = paste0(dom_node,"_Sibling"), Num_Sibling_Nodes = length(sibling_nodes) - 1, Sibling_Node_Leaves = sibling_node_leaves, Sibling_Leaves_Total = length(sibling_leaves)+sibling_node_leaves)))
            # Add dominant node leaves to leaf list
            node_compare_leaves <- rbindlist(list(node_compare_leaves,data.frame(Node = dom_node, Leaf = Descendants(tree, dom_node, type = "tips")[[1]])))
            # Add non-dominant node leaves to leaf list
            for (j in sibling_nodes){
            if (j != dom_node){
                node_compare_leaves <- rbindlist(list(node_compare_leaves,data.frame(Node = paste0(dom_node,"_Sibling"), Leaf = Descendants(tree, j, type = "tips")[[1]])))
            }
            }
            if (length(sibling_leaves) > 0){node_compare_leaves <- rbindlist(list(node_compare_leaves,data.frame(Node = paste0(dom_node,"_Sibling"), Leaf = sibling_leaves)))}
        }
        node_skip_list <- c(node_skip_list,sibling_nodes)
        }
    }
    node_compare_leaves <- node_compare_leaves %>% left_join(data.table(Leaf = 1:num_leaves,Barcode = tree$tip.label))
    list(node_compare_list,node_compare_leaves)
}

# Perform tasks
# Requires the tree name within the input folder to be called "OptimalTree.nw"
ts_tree <- read.tree(paste0(tree_dir,"/OptimalTree.nw"))
tree_relab <- tree_node_relabel(ts_tree)
write.tree(tree_relab,paste0(output_dir,"/OptimalTree_pruned.nw"))
tree_node_info <- node_info_extract(tree_relab)
tree_node_info_rows <- nrow(tree_node_info)
tree_node_count <- length(read.tree(paste0(output_dir,"/OptimalTree_pruned.nw"))$node.label)
tree_node_info %>% write.table(paste0(output_dir,"/OptimalTree_pruned_node_info.txt"),quote=F,sep="\t",row.names=F,col.names=T)
node_compare_objs <- node_compare_extract(tree_relab,tree_node_info)
node_compare_list <- node_compare_objs[[1]]
node_compare_leaves <- node_compare_objs[[2]]
node_compare_list %>% write.table(paste0(output_dir,"/OptimalTree_pruned_node_compare_list.txt"),quote=F,sep="\t",row.names=F,col.names=T)
node_compare_leaves %>% write.table(paste0(output_dir,"/OptimalTree_pruned_node_compare_leaves.txt"),quote=F,sep="\t",row.names=F,col.names=T)