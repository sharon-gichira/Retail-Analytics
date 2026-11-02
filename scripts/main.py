import pandas as pd
from pathlib import Path

DATA = Path(r"C:\Users\sharo\OneDrive\Desktop\Projects\LuxCapstone\data\kenya_retail")
t = pd.read_csv(DATA / "transactions.csv")

t["disc_pct"] = t["discount_kes"] / t["gross_sales_kes"]
print(t.loc[t["discount_kes"] > 0, "disc_pct"].describe(percentiles=[.25, .5, .75, .9]))