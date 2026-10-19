"""Generate a fake retail orders CSV for the Snowflake beginner project."""
import csv
import random
from datetime import date, timedelta

random.seed(42)

CUSTOMERS = [f"Customer {i:03d}" for i in range(1, 101)]
CATEGORIES = {"Furniture": 0.10, "Technology": 0.25, "Office Supplies": 0.18}
REGIONS = ["East", "West", "Central", "South"]
START = date(2023, 1, 1)
DAYS = 730  # two years of data
ROWS = 5000

with open("orders.csv", "w", newline="", encoding="utf-8") as f:
    writer = csv.writer(f)
    writer.writerow(["order_id", "order_date", "customer", "category", "region", "sales", "profit"])
    for i in range(1, ROWS + 1):
        category = random.choice(list(CATEGORIES))
        sales = round(random.uniform(10, 2000), 2)
        # profit margin varies around the category's base margin
        profit = round(sales * (CATEGORIES[category] + random.uniform(-0.15, 0.10)), 2)
        writer.writerow([
            f"ORD-{i:05d}",
            (START + timedelta(days=random.randrange(DAYS))).isoformat(),
            random.choice(CUSTOMERS),
            category,
            random.choice(REGIONS),
            sales,
            profit,
        ])

print(f"Wrote {ROWS} rows to orders.csv")
