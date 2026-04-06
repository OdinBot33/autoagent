FROM autoagent-base
RUN mkdir -p /app/data /app/output /logs

# Generate test CSV with some dirty data
RUN python3 -c "
import csv, random, datetime
random.seed(42)
products = ['Widget A', 'Widget B', 'Gadget X', 'Gadget Y', 'Tool Z']
with open('/app/data/sales.csv', 'w', newline='') as f:
    w = csv.writer(f)
    w.writerow(['id', 'date', 'product', 'amount', 'customer'])
    for i in range(100):
        date = datetime.date(2024, random.randint(1,12), random.randint(1,28))
        product = random.choice(products)
        amount = round(random.uniform(10, 500), 2)
        # Add some dirty rows
        if i % 20 == 0:
            w.writerow([i+1, '', product, '', f'Customer_{i}'])  # missing values
        elif i % 25 == 0:
            w.writerow([i+1, date.strftime('%m/%d/%Y'), product, f'\${amount}', f'Customer_{i}'])  # dollar sign
        else:
            w.writerow([i+1, date.strftime('%Y-%m-%d'), product, f'\${amount}', f'Customer_{i}'])
"

WORKDIR /app
