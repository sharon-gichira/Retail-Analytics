## Data

### Source and approach
No public dataset combines Kenyan store locations, county-level sales and M-Pesa
payments, so this project adapts a real retail dataset to a Kenyan context.

The base is the **Dunnhumby "The Complete Journey"** dataset (Kaggle): real grocery
transactions from about 2,500 households over two years. `data.py` transforms it into the four tables below.

**Real (from Dunnhumby):** basket composition, product mix, purchase timing patterns,
promotions and discounts, household purchasing behaviour.

**Simulated (added by this project):** counties, store attributes, KES prices,
payment methods, M-Pesa references, customer signup dates and loyalty tiers.

### Tables (in `data/kenya_retail/`)

| File | Grain | Description |
|---|---|---|
| `transactions.csv` | One row per product line | Date, hour, store, customer, product, quantity, KES prices, discount, promo flag/type, payment method, payment reference |
| `stores.csv` | One row per store | County, urbanisation tier, format, size (sqm), year opened |
| `customers.csv` | One row per customer | Home county, signup date, loyalty tier, age band, household size, kids |
| `products.csv` | One row per product | Category, product group and subgroup, brand |

**Size:** about 1.8M transaction lines, about 169,600 baskets, 60 stores in 20 counties,
2,280 customers and about 62,800 products, from 2024-01-01 to 2025-12-11.

### How the Kenyan layer was built
- **Counties:** the 60 busiest stores were assigned to 20 counties with probability
  weighted by approximate 2019 census population, and tagged Urban, Peri-urban or Rural.
  A customer's home county is the county of their most-used store, and about 15% of purchases happen outside it.
- **Prices:** US prices were converted at 129 KES/USD and scaled by 0.55 to approximate
  Kenyan shelf prices, then rounded to 5 KES steps.
- **Payments:** a payment method is assigned per basket using a probability model.
  M-Pesa is more likely for small and mid-sized baskets, card for large urban baskets and
  cash for rural stores. Overall mix: about 63% M-Pesa, 23% cash, 9% card, 4% Airtel Money,
  under 1% bank transfer. M-Pesa and Airtel Money baskets receive a random 10-character
  transaction code.
- **Promotions:** a line counts as a promotion if it carries a coupon or shelf discount
  of at least 25% (about 25% of lines). Smaller discounts are labelled "Loyalty discount".
- **Cleaning applied to the source:** non-grocery items (gift cards, seasonal goods,
  miscellaneous transactions) were removed, as were extreme lines (over KES 15,000)
  and baskets under KES 20.
- **Deliberate messiness:** about 8% of baskets have no customer ID, plus a small number of
  duplicate rows and blank payment methods, so the data needs real cleaning.

### Limitations
- Counties, store attributes and payment fields are **simulated**. Patterns in them
  reflect the rules above, not observed Kenyan customer behaviour, so findings about payment
  mix by county or basket size should not be read as empirical results.
- Seasonality follows the original US calendar, not Kenyan paydays, school terms or holidays.
- County populations are approximate and the payment shares are assumptions,
  not calibrated figures.