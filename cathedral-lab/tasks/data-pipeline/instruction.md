# Task: Data Processing Pipeline

Build a data pipeline in `/app/pipeline.py` that:

1. Reads the CSV file at `/app/data/sales.csv`
2. Cleans the data:
   - Remove rows with missing values
   - Normalize the "amount" column (remove $ signs, convert to float)
   - Parse dates in "date" column to YYYY-MM-DD format
3. Analyzes the data:
   - Total revenue
   - Average order value
   - Top 3 products by revenue
   - Monthly revenue breakdown
4. Writes results to `/app/output/report.json`

The report.json should have this structure:
```json
{
  "total_revenue": 12345.67,
  "avg_order_value": 123.45,
  "top_products": [{"product": "name", "revenue": 1234.56}, ...],
  "monthly_revenue": {"2024-01": 1234.56, ...},
  "rows_cleaned": 5,
  "rows_processed": 95
}
```

Use only Python standard library (csv, json, datetime). No pandas.
