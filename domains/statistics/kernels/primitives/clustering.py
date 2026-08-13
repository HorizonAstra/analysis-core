'''
- DBSCAN Clustering
'''

import numpy as np
from typing import Dict, Any
from sklearn.cluster import DBSCAN
from sklearn.metrics import silhouette_score


def dbscan_clustering(X: np.ndarray, eps: float, min_samples: int) -> Dict[str, Any]:
    """
    Perform DBSCAN clustering analysis.
    Identifies clusters and noise points in the data.
    """
    dbscan = DBSCAN(eps=eps, min_samples=min_samples)
    cluster_labels = dbscan.fit_predict(X)

    # Calculate statistics
    n_clusters = len(set(cluster_labels)) - (1 if -1 in cluster_labels else 0)
    n_noise = list(cluster_labels).count(-1)
    n_points = len(cluster_labels)

    # Silhouette score is only defined with >1 cluster and some non-noise points;
    # this guard is algorithmic, not error reporting, so it stays here.
    silhouette_avg = None
    if n_clusters > 1 and n_noise < n_points:
        try:
            silhouette_avg = silhouette_score(X, cluster_labels)
        except ValueError:
            silhouette_avg = None

    # Group points by cluster
    clusters = {}
    for i, label in enumerate(cluster_labels):
        clusters.setdefault(label, []).append(i)

    return {
        "analysis_type": "dbscan_clustering",
        "eps": eps,
        "min_samples": min_samples,
        "n_clusters": n_clusters,
        "n_noise_points": n_noise,
        "n_total_points": n_points,
        "silhouette_score": silhouette_avg,
        "cluster_labels": cluster_labels.tolist(),
        "clusters": {str(k): v for k, v in clusters.items()},
        "data_points": X.tolist()
    }