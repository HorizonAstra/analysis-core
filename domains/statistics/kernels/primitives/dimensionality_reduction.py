'''
- t-SNE Analysis

(PCoA lives in the ordination block, alongside PERMANOVA/PERMDISP, since it operates
on a distance matrix rather than a raw feature matrix.)
'''

import numpy as np
from typing import Dict, Any
from sklearn.manifold import TSNE


def tsne_analysis(X: np.ndarray, n_components: int, perplexity: float, learning_rate: float) -> Dict[str, Any]:
    """
    Perform t-SNE dimensionality reduction analysis.
    Reduces high-dimensional data to 2D or 3D for visualization.
    """
    # Adjust perplexity if too large
    max_perplexity = min(30, X.shape[0] - 1)
    perplexity = min(perplexity, max_perplexity)

    tsne = TSNE(n_components=n_components, perplexity=perplexity, learning_rate=learning_rate, random_state=42)
    X_embedded = tsne.fit_transform(X)

    x_coords = X_embedded[:, 0].tolist()
    y_coords = X_embedded[:, 1].tolist()
    z_coords = X_embedded[:, 2].tolist() if n_components == 3 else None

    return {
        "analysis_type": "tsne",
        "n_components": n_components,
        "perplexity": perplexity,
        "learning_rate": learning_rate,
        "n_points": X.shape[0],
        "original_dimensions": X.shape[1],
        "x_coordinates": x_coords,
        "y_coordinates": y_coords,
        "z_coordinates": z_coords,
        "original_data": X.tolist()
    }