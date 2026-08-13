'''
- Apriori Algorithm
'''

import math
import pandas as pd
from typing import List, Dict, Any
from mlxtend.frequent_patterns import apriori, association_rules
from mlxtend.preprocessing import TransactionEncoder

def apriori_analysis(transactions: List[List], min_support: float, min_confidence: float, min_lift: float) -> Dict[str, Any]:
    """
    Perform Apriori algorithm for association rule mining using mlxtend.
    Discovers all frequent k-itemsets (k >= 1) and generates association rules
    filtered by minimum support, confidence, and lift thresholds.
    """
    te = TransactionEncoder()
    te_array = te.fit(transactions).transform(transactions)
    df = pd.DataFrame(te_array, columns=te.columns_)

    frequent_itemsets = apriori(df, min_support=min_support, use_colnames=True)

    itemsets_output = []
    for _, row in frequent_itemsets.iterrows():
        itemsets_output.append({
            "itemset": sorted(list(row['itemsets'])),
            "support": float(row['support']),
            "length": len(row['itemsets'])
        })

    if frequent_itemsets.empty or not any(row['length'] >= 2 for row in itemsets_output):
        return {
            "analysis_type": "apriori",
            "min_support": min_support,
            "min_confidence": min_confidence,
            "min_lift": min_lift,
            "total_transactions": len(transactions),
            "n_frequent_itemsets": len(frequent_itemsets),
            "frequent_itemsets": itemsets_output,
            "association_rules": [],
            "n_rules": 0
        }

    rules_df = association_rules(frequent_itemsets, metric="confidence", min_threshold=min_confidence)
    rules_df = rules_df[rules_df['lift'] >= min_lift]

    rules_output = []
    for _, row in rules_df.iterrows():
        conviction_val = float(row['conviction'])
        if math.isinf(conviction_val) or math.isnan(conviction_val):
            conviction_val = None

        rules_output.append({
            "antecedent": sorted(list(row['antecedents'])),
            "consequent": sorted(list(row['consequents'])),
            "antecedent_support": float(row['antecedent support']),
            "consequent_support": float(row['consequent support']),
            "support": float(row['support']),
            "confidence": float(row['confidence']),
            "lift": float(row['lift']),
            "leverage": float(row['leverage']),
            "conviction": conviction_val
        })

    return {
        "analysis_type": "apriori",
        "min_support": min_support,
        "min_confidence": min_confidence,
        "min_lift": min_lift,
        "total_transactions": len(transactions),
        "n_frequent_itemsets": len(frequent_itemsets),
        "frequent_itemsets": itemsets_output,
        "association_rules": rules_output,
        "n_rules": len(rules_output)
    }
