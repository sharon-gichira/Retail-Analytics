# Kenya Retail Analytics

End-to-end retail analytics on a Kenyan supermarket dataset: data cleaning, exploratory analysis, SQL analytics in PostgreSQL, statistical testing, and predictive modelling. The data is built from real Dunnhumby transaction behaviour and adapted to Kenyan counties, KES prices and M-Pesa payments.

> **Important: the data is not in this repository.** The dataset has over 1.8 million transaction lines and is far too large to commit to GitHub, so `data/dunnhumby/` and `data/kenya_retail/` are listed in `.gitignore`. Follow [Reproducing the project](#reproducing-the-project) to regenerate everything from the public source data.

---

## Problem statement

A retail chain with 60 stores across 20 Kenyan counties has transaction data but no unified view of what drives its sales. It does not know which stores, categories and customers generate the most revenue, whether its promotions create real incremental sales or just discount purchases that would have happened anyway, or how to plan demand. This project builds an analytics pipeline from raw data to recommendations that answers those questions.

## Objectives

1. **Sales performance:** identify which counties, store formats and product categories drive revenue, and how sales trend over time and by weekday.
2. **Promotion effectiveness:** measure the lift in units and revenue from promotions, compare it by discount depth and category, and find promotions that do not pay off.
3. **Customer segmentation:** segment customers with RFM (recency, frequency, monetary value) and clustering, then profile each segment and recommend actions.
4. **Demand forecasting:** forecast weekly sales by category and test whether a model beats simple baselines.
5. **Recommendations:** turn the findings into concrete business recommendations.

---

## Data

### Source and approach

Couldn't find a public dataset that combines Kenyan store locations, county-level sales and M-Pesa payments, so this project adapts a real retail dataset to a Kenyan context.

The base is the **Dunnhumby "The Complete Journey"** dataset (Kaggle): real grocery transactions from about 2,500 households over two years. A build script (`Scripts/data.py`) transforms it into four tables.

**Real (from Dunnhumby):** basket composition, product mix, purchase timing patterns, promotions and discounts, household purchasing behaviour.

**Simulated (added by this project):** counties, store attributes, KES prices, payment methods, M-Pesa references, customer signup dates and loyalty tiers.

### Tables (in `data/kenya_retail/`, not committed)

| File | Grain | Description |
|---|---|---|
| `transactions.csv` | One row per product line | Date, hour, store, customer, product, quantity, KES prices, discount, promo flag and type, payment method, payment reference |
| `stores.csv` | One row per store | County, urbanisation tier, format, size (sqm), year opened |
| `customers.csv` | One row per customer | Home county, signup date, loyalty tier, age band, household size, kids |
| `products.csv` | One row per product | Category, product group and subgroup, brand |

**Size:** about 1.8M transaction lines, about 170,000 baskets, 60 stores in 20 counties, 2,280 customers and about 62,800 products, from 1 January 2024 to 11 December 2025.

### How the Kenyan layer was built

- **Counties:** the 60 busiest stores were assigned to 20 counties with probability weighted by approximate 2019 census population, and tagged Urban, Peri-urban or Rural. A customer's home county is the county of their most-used store, and about 15% of purchases happen outside it.
- **Prices:** US prices were converted at 129 KES/USD and scaled by 0.55 to approximate Kenyan shelf prices, then rounded to 5 KES steps.
- **Payments:** a payment method is assigned per basket using a probability model. M-Pesa is more likely for small and mid-sized baskets, card for large urban baskets and cash for rural stores. Overall mix: about 63% M-Pesa, 23% cash, 9% card, 4% Airtel Money, under 1% bank transfer. M-Pesa and Airtel Money baskets receive a random 10-character transaction code.
- **Promotions:** a line counts as a promotion if it carries a coupon or shelf discount of at least 25% (about 25% of lines). Smaller discounts are labelled "Loyalty discount".
- **Cleaning applied to the source:** non-grocery items (gift cards, seasonal goods, miscellaneous transactions) were removed, as were extreme lines (over KES 15,000) and baskets under KES 20.
- **Deliberate messiness:** about 8% of baskets have no customer ID, plus a small number of duplicate rows and blank payment methods, so the data needs real cleaning.

### Why the data is gitignored

The data is massive. The transactions file alone has more than 1.8 million rows, and together with the raw Dunnhumby files it is far too large for a normal GitHub repository. GitHub rejects files over 100 MB, and committing large CSVs would bloat the repository history permanently. So the following are excluded in `.gitignore`:

```
data/dunnhumby/
data/kenya_retail/
```

The repository contains the code that produces the data, not the data itself. Anyone can rebuild it in a few minutes by following the steps below. This also respects the source dataset's license, because the raw Dunnhumby files are not redistributed.

---

## Repository structure

```
Kenya Retails/
├── .gitignore
├── README.md
├── data/
│   ├── dunnhumby/              # Raw source files (gitignored)
│   └── kenya_retail/           # Generated tables (gitignored)
├── notebooks/
│   └── main.ipynb              # Cleaning, EDA, promo analysis, statistics, modelling
└── scripts/
    ├── data.py                 # Data extraction and preprocessing modules
    ├── main.py                 # Orchestrates and builds the Kenyan dataset
    └── retail.sql              # PostgreSQL: schema, load, audit, clean, analysis
  
```
  
---

## Reproducing the project

### 1. Get the source data

Download **Dunnhumby "The Complete Journey"** from Kaggle and unzip it into `data/dunnhumby/`. The build script needs `transaction_data.csv`, `product.csv` and `hh_demographic.csv`. Check the dataset's license terms on Kaggle first.

### 2. Set up Python

```bash
python -m venv venv
venv\Scripts\activate
pip install -r requirements.txt
```

Main libraries: `pandas`, `numpy`, `scikit-learn`, `scipy`, `matplotlib`.

### 3. Build the dataset

```bash
python Scripts/data.py
```

This writes the four CSV files to `data/kenya_retail/`. All parameters (FX rate, price scale, promo threshold, number of stores) are set at the top of the script, and it prints sanity checks at the end (payment mix, promo share, basket sizes).

### 4. Run the notebook

Open `notebooks/main.ipynb` and use **Restart Kernel and Run All Cells**. The promotion analysis takes a few minutes.

### 5. SQL Analytics

All database schemas, data quality audits, and data analysis queries were performed using **PostgreSQL** and are saved for version control and reference in:
* `scripts/retail.sql`
```

The script creates the `kenya_retail` database and a `retail` schema, loads the CSVs into a raw staging table, audits and cleans them into the final tables, and runs the analysis queries.

```

## Methods

**Data cleaning and preparation.** The raw tables are audited before any change: column types, missing values, duplicates, arithmetic consistency (net equals gross minus discount), valid store, product and customer IDs, and sensible ranges. Duplicate rows are removed by line ID, blank payment methods are labelled "Unknown", and baskets with no customer ID are kept and flagged as anonymous shoppers. A small number of negative-discount lines (items sold above base price) are kept as they are. The tables are then merged and week, month and weekday columns added.

**Exploratory analysis.** Distributions of basket value, quantity and discount depth; monthly and weekly trends; weekday and hourly patterns; and differences across stores, store formats, counties, categories and customer segments. County comparisons are shown per store, since totals mainly reflect how many stores each county received.

**SQL analytics.** The same cleaning pipeline and analyses in PostgreSQL: sales by county, format and category, monthly trend, weekday and hour patterns, promotion lift by discount depth and category, failing promotions, RFM segment profiles, forecast baselines and distribution summaries.

**Statistical analysis.** Promotion lift is estimated by comparing promoted weeks with the same product's non-promoted weeks in the same store, counting a week as promotional only when at least 80% of its units sold on promotion. Results come with bootstrap confidence intervals and Wilcoxon tests. Other tests: Spearman correlation between discount depth and lift, a Kruskal-Wallis test for weekday differences, trend tests after the early ramp-up, and paired tests on forecast errors.

**Predictive modelling.** (1) Weekly sales forecasting for the eight largest categories with gradient boosting on lag features, tested on the last 12 full weeks against three baselines: same as last week, four-week average and same week last year. (2) Customer segmentation with K-means on log-scaled recency, frequency and monetary value, and a rule-based RFM scoring cross-check in SQL.

---

## Key findings

- **Sales are flat after an initial ramp-up.** Weekly sales climb from about KES 0.4M in January 2024 to about 3.7M by April, then hold near KES 3.9M a week. The ramp most likely reflects panel households becoming active.
- **A recurring mid-November peak appears in both years.** It comes from the original US shoppers, so it is not evidence of Kenyan seasonality.
- **Baskets are small and right-skewed.** The median basket is about KES 1,200, well below the mean, so medians and percentiles are reported.
- **Deeper promotions did not sell more.** For fast-moving products, unit sales stayed near normal in promoted weeks, so revenue per promoted product fell as discounts deepened [update with the final lift and confidence intervals]. Margin cannot be assessed without cost data.
- **A simple seasonal baseline was the best forecast.** Using the same week last year gave an average error of 9.7% (MAPE), versus 12.2% for last week's value and 11.6% for the gradient-boosting model. With only about one year of post-ramp history, the model could not improve on it.
- - **Customer segments:** K-means on log-scaled recency, frequency and spend splits the 2,273 identified customers into four segments. Spend is highly concentrated: 919 Champions (40% of customers) account for 77% of spend. The best win-back target is the 535 at-risk regulars, who shopped regularly but have not bought for about 53 days and hold 16% of spend. The 357 lapsed customers (inactive for about six months, 1% of spend) are not worth targeted spend. Anonymous baskets (about 8%) are excluded, and because the source is a fixed household panel, some long-inactive households may simply have left the study.

| Segment | Customers | % of customers | % of spend | Median recency (days) | Median baskets | Median spend (KES) | Recommended action |
|---|---|---|---|---|---|---|---|
| Champions | 919 | 40% | 77% | 4 | 103 | 234,815 | Reward and protect: loyalty perks, early access to offers |
| Lapsed (cluster 0) | 535 | 24% | 16% | 53 | 37 | 80,229 | Low-cost reactivation, or deprioritise |
| Occasional shoppers | 462 | 20% | 6% | 9 | 21 | 34,449 | Encourage repeat visits with light incentives |
| Lapsed (cluster 1) | 357 | 16% | 1% | 181 | 5 | 6,864 | Low-cost reactivation, or deprioritise |

---

## Limitations

- Counties, store attributes and payment fields are **simulated**. Patterns in them reflect the rules above, not observed Kenyan customer behaviour, so findings about payment mix by county or basket size should not be read as empirical results.
- Seasonality follows the original US calendar, not Kenyan paydays, school terms or holidays.
- County populations are approximate, and the payment shares are assumptions, not calibrated figures.
- The data covers a panel of about 2,500 households, not a chain's full customer base, so absolute revenue figures are small.
- Promotion results are associations, not causal effects, because promotions were not randomly assigned. Revenue is not margin, and effects on other items in the basket were not measured.
- Forecast results rest on a 12-week test window and one prior year of history.

---

## Tech stack

Python (pandas, NumPy, scikit-learn, SciPy, Matplotlib), Jupyter, PostgreSQL.

## Author

Sharon: [github.com/sharon-gichira](https://github.com/sharon-gichira)

## License and attribution

Code in this repository: [add your license, e.g. MIT]. The underlying data comes from the Dunnhumby "The Complete Journey" dataset, which is subject to its own license terms on Kaggle and is not redistributed here.