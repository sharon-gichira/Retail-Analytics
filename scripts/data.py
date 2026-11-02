from pathlib import Path
import numpy as np
import pandas as pd

BASE = Path(__file__).resolve().parent
RAW = BASE / "dunnhumby"
OUT = BASE / "kenya_retail"
SEED = 42

START_DATE = pd.Timestamp("2024-01-01")
N_STORES = 60
USD_TO_KES = 129.0
PRICE_SCALE = 0.55
MAX_LINE_QTY = 50
MAX_LINE_KES = 15000
MIN_BASKET_KES = 20
MIN_PROMO_PCT = 0.25          
MISSING_CUSTOMER_RATE = 0.08
STRICT_HOME_COUNTY = False
ADD_MESSINESS = True

DROP_DEPARTMENTS = [
    "MISC. TRANS.", "MISC SALES TRAN", "KIOSK-GAS", "TRAVEL & LEISURE",
    "GARDEN CENTER", "AUTOMOTIVE", "COUP/STR & MFG", "RX",
]

rng = np.random.default_rng(SEED)
OUT.mkdir(exist_ok=True)

COUNTIES = pd.DataFrame(
    [
        ("Nairobi", 4.40, "Urban"), ("Mombasa", 1.21, "Urban"),
        ("Kisumu", 1.16, "Urban"), ("Nakuru", 2.16, "Urban"),
        ("Kiambu", 2.42, "Urban"), ("Uasin Gishu", 1.16, "Urban"),
        ("Machakos", 1.42, "Peri-urban"), ("Kajiado", 1.12, "Peri-urban"),
        ("Nyeri", 0.76, "Peri-urban"), ("Meru", 1.55, "Peri-urban"),
        ("Kirinyaga", 0.61, "Peri-urban"), ("Murang'a", 1.06, "Peri-urban"),
        ("Embu", 0.61, "Peri-urban"), ("Laikipia", 0.52, "Peri-urban"),
        ("Kakamega", 1.87, "Rural"), ("Bungoma", 1.67, "Rural"),
        ("Kilifi", 1.45, "Rural"), ("Kisii", 1.27, "Rural"),
        ("Kericho", 0.90, "Rural"), ("Trans Nzoia", 0.99, "Rural"),
    ],
    columns=["county", "population_m", "tier"],
)
COUNTIES["weight"] = COUNTIES["population_m"] / COUNTIES["population_m"].sum()
tier_of_county = COUNTIES.set_index("county")["tier"].to_dict()

# ---------------------------------------------------------------- 1. LOADING + CLEANING
print("Loading Dunnhumby files from", RAW)
tx = pd.read_csv(RAW / "transaction_data.csv")
tx.columns = tx.columns.str.lower()
prod = pd.read_csv(RAW / "product.csv")
prod.columns = prod.columns.str.lower()
demo = pd.read_csv(RAW / "hh_demographic.csv")
demo.columns = demo.columns.str.lower()

tx = tx[(tx["quantity"] > 0) & (tx["quantity"] <= MAX_LINE_QTY) & (tx["sales_value"] > 0)].copy()

# dropping non-grocery items (gift cards, patio sets, misc transactions, etc.)
non_grocery = prod[
    prod["department"].isin(DROP_DEPARTMENTS)
    | prod["commodity_desc"].str.contains("SEASONAL|COUPON/MISC|GIFT CARD", na=False)
]["product_id"]
tx = tx[~tx["product_id"].isin(non_grocery)].copy()

top_stores = tx.groupby("store_id").size().sort_values(ascending=False).head(N_STORES).index
tx = tx[tx["store_id"].isin(top_stores)].copy()
print(f"  {len(tx):,} lines after filtering")

# ---------------------------------------------------------------- 2. STORES
store_volume = tx.groupby("store_id").size().sort_values(ascending=False)
store_ids = store_volume.index.to_numpy()
n = len(store_ids)

store_county = rng.choice(COUNTIES["county"], size=n, p=COUNTIES["weight"])
fmt = np.where(
    np.arange(n) < int(0.10 * n), "Hypermarket",
    np.where(np.arange(n) < int(0.50 * n), "Supermarket", "Mini-market"),
)
size_lo = {"Hypermarket": 3000, "Supermarket": 900, "Mini-market": 150}
size_hi = {"Hypermarket": 6000, "Supermarket": 2500, "Mini-market": 600}

stores = pd.DataFrame({
    "store_id": [f"KE-ST{i+1:03d}" for i in range(n)],
    "source_store_id": store_ids,
    "county": store_county,
    "format": fmt,
})
stores["tier"] = stores["county"].map(tier_of_county)
stores["size_sqm"] = [int(rng.integers(size_lo[f], size_hi[f])) for f in stores["format"]]
stores["opened_year"] = rng.integers(2005, 2023, size=n)

store_key = stores.set_index("source_store_id")
tx["store_code"] = tx["store_id"].map(store_key["store_id"])
tx["store_county"] = tx["store_id"].map(store_key["county"])
tx["store_tier"] = tx["store_id"].map(store_key["tier"])

# ---------------------------------------------------------------- 3. CUSTOMERS
hh_store = tx.groupby("household_key")["store_id"].agg(lambda s: s.mode().iat[0])
hh_county = hh_store.map(store_key["county"])
tx["customer_county"] = tx["household_key"].map(hh_county)

cross_rate = (tx["customer_county"] != tx["store_county"]).mean()
print(f"  Lines bought outside the customer's home county: {cross_rate:.1%}")
if STRICT_HOME_COUNTY:
    tx = tx[tx["customer_county"] == tx["store_county"]].copy()

tx["day"] = tx["day"].astype(int)
tx["date"] = START_DATE + pd.to_timedelta(tx["day"] - 1, unit="D")

# ---------------------------------------------------------------- 4. PRICES + PROMOS
gross_usd = tx["sales_value"] - tx["retail_disc"] - tx["coupon_match_disc"]
fx = USD_TO_KES * PRICE_SCALE

unit_kes = np.maximum(5, np.round(gross_usd / tx["quantity"] * fx / 5) * 5)
gross_kes = unit_kes * tx["quantity"]
disc_kes = np.round((-tx["retail_disc"] - tx["coupon_match_disc"]) * fx)
disc_kes = np.minimum(disc_kes, 0.6 * gross_kes)

tx["unit_price_kes"] = unit_kes
tx["gross_sales_kes"] = gross_kes
tx["discount_kes"] = disc_kes
tx["net_sales_kes"] = gross_kes - disc_kes

promo_pct = tx["discount_kes"] / tx["gross_sales_kes"]
tx["promo_type"] = np.select(
    [
        (tx["coupon_match_disc"] < 0) & (promo_pct >= MIN_PROMO_PCT),
        (tx["retail_disc"] < 0) & (promo_pct >= MIN_PROMO_PCT),
        tx["discount_kes"] > 0,
    ],
    ["Coupon", "Shelf promo", "Loyalty discount"],
    default="None",
)
tx["promo_flag"] = tx["promo_type"].isin(["Coupon", "Shelf promo"]).astype(int)

# outlier backstop
tx = tx[tx["net_sales_kes"] <= MAX_LINE_KES].copy()
basket_total = tx.groupby("basket_id")["net_sales_kes"].transform("sum")
tx = tx[basket_total >= MIN_BASKET_KES].copy()

tx["hour"] = (tx["trans_time"] // 100).clip(0, 23)

# customers table (built after filtering so only active households remain)
hh = pd.DataFrame({"household_key": hh_county.index, "county": hh_county.values})
hh = hh[hh["household_key"].isin(tx["household_key"].unique())]
hh = hh.merge(
    demo[["household_key", "age_desc", "household_size_desc", "kid_category_desc"]],
    on="household_key", how="left",
).rename(columns={"age_desc": "age_band", "household_size_desc": "household_size",
                  "kid_category_desc": "kids"})

first_buy = tx.groupby("household_key")["date"].min()
spend = tx.groupby("household_key")["sales_value"].sum()
hh["customer_id"] = [f"C{i+1:05d}" for i in range(len(hh))]
hh["signup_date"] = hh["household_key"].map(first_buy) - pd.to_timedelta(
    rng.integers(0, 900, size=len(hh)), unit="D"
)
q = spend.rank(pct=True)
hh["loyalty_tier"] = pd.cut(
    hh["household_key"].map(q), bins=[0, 0.5, 0.85, 1.0],
    labels=["Bronze", "Silver", "Gold"], include_lowest=True,
)
tx["customer_id"] = tx["household_key"].map(hh.set_index("household_key")["customer_id"])

products = prod[prod["product_id"].isin(tx["product_id"].unique())][
    ["product_id", "department", "commodity_desc", "sub_commodity_desc", "brand"]
].rename(columns={"department": "category", "commodity_desc": "product_group",
                  "sub_commodity_desc": "product_subgroup"})

# ---------------------------------------------------------------- 5. PAYMENTS
baskets = tx.groupby("basket_id").agg(
    total=("net_sales_kes", "sum"), tier=("store_tier", "first"),
).reset_index()
total = baskets["total"].to_numpy()
tier = baskets["tier"].to_numpy()


def tier_mult(urban, peri, rural):
    return np.where(tier == "Urban", urban, np.where(tier == "Peri-urban", peri, rural))


# Base shares are assumptions: calibrate against CBK mobile payments data.
w_mpesa = 0.62 * np.where(total < 1500, 1.15, np.where(total > 8000, 0.65, 1.0)) * tier_mult(1.0, 1.0, 0.95)
w_cash = (0.20 * np.where(total > 8000, 1.2, 1.0) * np.where(total < 300, 1.4, 1.0)
          * tier_mult(0.8, 1.0, 1.5))
w_card = (0.10 * np.where(total > 5000, 2.0, np.where(total < 500, 0.3, 1.0))
          * tier_mult(1.8, 0.8, 0.25))
w_airtel = np.full(len(baskets), 0.04)
w_bank = 0.02 * np.where(total > 10000, 3.0, 0.3)

methods = np.array(["M-Pesa", "Cash", "Card", "Airtel Money", "Bank Transfer"])
W = np.vstack([w_mpesa, w_cash, w_card, w_airtel, w_bank]).T
P = W / W.sum(axis=1, keepdims=True)
choice = (rng.random(len(P))[:, None] > P.cumsum(axis=1)).sum(axis=1)
baskets["payment_method"] = methods[choice]

chars = np.array(list("ABCDEFGHJKLMNPQRSTUVWXYZ0123456789"))
mobile = baskets["payment_method"].isin(["M-Pesa", "Airtel Money"]).to_numpy()
idx = rng.integers(0, len(chars), size=(mobile.sum(), 10))
refs = np.full(len(baskets), None, dtype=object)
refs[mobile] = np.array(["".join(r) for r in chars[idx]])
baskets["payment_ref"] = refs
assert baskets["payment_ref"].dropna().is_unique

baskets["no_customer"] = rng.random(len(baskets)) < MISSING_CUSTOMER_RATE
tx = tx.merge(baskets[["basket_id", "payment_method", "payment_ref", "no_customer"]],
              on="basket_id", how="left")
tx.loc[tx["no_customer"], "customer_id"] = np.nan

# ---------------------------------------------------------------- 6. SAVE
tx = tx.sort_values(["date", "basket_id"]).reset_index(drop=True)
transactions = pd.DataFrame({
    "line_id": np.arange(1, len(tx) + 1),
    "basket_id": tx["basket_id"],
    "date": tx["date"].dt.date,
    "hour": tx["hour"],
    "store_id": tx["store_code"],
    "customer_id": tx["customer_id"],
    "product_id": tx["product_id"],
    "quantity": tx["quantity"],
    "unit_price_kes": tx["unit_price_kes"],
    "gross_sales_kes": tx["gross_sales_kes"],
    "discount_kes": tx["discount_kes"],
    "net_sales_kes": tx["net_sales_kes"],
    "promo_flag": tx["promo_flag"],
    "promo_type": tx["promo_type"],
    "payment_method": tx["payment_method"],
    "payment_ref": tx["payment_ref"],
})

if ADD_MESSINESS:
    dups = transactions.sample(frac=0.002, random_state=SEED)
    transactions = pd.concat([transactions, dups], ignore_index=True)
    blank_idx = transactions.sample(frac=0.003, random_state=SEED + 1).index
    transactions.loc[blank_idx, "payment_method"] = np.nan

customers = hh[["customer_id", "county", "signup_date", "loyalty_tier",
                "age_band", "household_size", "kids"]].copy()
customers["signup_date"] = customers["signup_date"].dt.date
stores_out = stores[["store_id", "county", "tier", "format", "size_sqm", "opened_year"]]

transactions.to_csv(OUT / "transactions.csv", index=False)
stores_out.to_csv(OUT / "stores.csv", index=False)
customers.to_csv(OUT / "customers.csv", index=False)
products.to_csv(OUT / "products.csv", index=False)

# ---------------------------------------------------------------- 7. CHECKS
print("\nDone. Files written to", OUT)
print(f"Date range: {transactions['date'].min()} -> {transactions['date'].max()}")
print(f"Rows: {len(transactions):,} | baskets: {len(baskets):,} | stores: {len(stores_out)} "
      f"| customers: {len(customers):,} | products: {len(products):,}")
print("\nPayment share (baskets):")
print(baskets["payment_method"].value_counts(normalize=True).round(3).to_string())
print(f"\nPromo lines: {tx['promo_flag'].mean():.1%}  (target roughly 15-30%)")
b = tx.groupby("basket_id")["net_sales_kes"].sum()
print(f"Basket KES: min {b.min():.0f} | median {b.median():.0f} | max {b.max():.0f}")