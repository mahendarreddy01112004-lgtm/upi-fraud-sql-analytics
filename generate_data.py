"""
generate_data.py
-----------------
Generates realistic synthetic data for the UPI Transactions & Fraud
Pattern Analytics project and loads it into a SQLite database
(upi_transactions.db) using schema.sql.

Fraud patterns deliberately injected into the data so the analysis
queries have real signal to detect:
  1. VELOCITY FRAUD   - a small set of users firing 6-10 transactions
                         within a 2-minute window (bot-like behaviour).
  2. ODD-HOUR HIGH-VALUE - a few users making unusually large
                         transactions between 1 AM - 4 AM.
  3. FAILED-RETRY BURST - a user attempting the same amount to the
                         same merchant repeatedly after failures
                         (card/UPI testing pattern).
  4. GEO-MISMATCH     - a transaction city far from the user's home
                         city on the same day as a normal transaction
                         (impossible travel pattern).

Run:  python3 generate_data.py
"""

import sqlite3
import random
from datetime import datetime, timedelta

random.seed(42)

DB_PATH = "upi_transactions.db"
SCHEMA_PATH = "schema.sql"

INDIAN_FIRST_NAMES = ["Aarav","Vivaan","Aditya","Vihaan","Arjun","Sai","Reyansh","Krishna",
    "Ishaan","Rohan","Ananya","Diya","Priya","Sneha","Kavya","Isha","Riya","Meera",
    "Aditi","Neha","Rahul","Karthik","Suresh","Ramesh","Lakshmi","Divya","Pooja",
    "Manoj","Sandeep","Vikram","Anjali","Swathi","Harish","Naveen","Deepak","Nikhil"]
INDIAN_LAST_NAMES = ["Reddy","Sharma","Verma","Iyer","Nair","Rao","Gupta","Patel",
    "Kumar","Singh","Das","Chowdhury","Menon","Pillai","Naidu","Mehta","Joshi","Kapoor"]

CITIES_STATES = [
    ("Hyderabad","Telangana"), ("Bengaluru","Karnataka"), ("Chennai","Tamil Nadu"),
    ("Mumbai","Maharashtra"), ("Pune","Maharashtra"), ("Delhi","Delhi"),
    ("Kolkata","West Bengal"), ("Ahmedabad","Gujarat"), ("Vijayawada","Andhra Pradesh"),
    ("Visakhapatnam","Andhra Pradesh"), ("Jaipur","Rajasthan"), ("Lucknow","Uttar Pradesh"),
    ("Kochi","Kerala"), ("Chandigarh","Chandigarh"), ("Indore","Madhya Pradesh")
]

BANKS = ["State Bank of India","HDFC Bank","ICICI Bank","Axis Bank","Punjab National Bank",
    "Kotak Mahindra Bank","Bank of Baroda","Canara Bank","IDFC FIRST Bank","Yes Bank"]

MERCHANT_CATEGORIES = ["Grocery","Food Delivery","Fuel","Travel","Electronics","Bill Payment",
    "Mobile Recharge","Pharmacy","Fashion","Entertainment","Education","Insurance"]

MERCHANT_NAMES = {
    "Grocery": ["BigBasket","DMart","Reliance Fresh","More Supermarket"],
    "Food Delivery": ["Swiggy","Zomato","EatSure"],
    "Fuel": ["Indian Oil","HP Petrol Pump","Bharat Petroleum"],
    "Travel": ["IRCTC","RedBus","MakeMyTrip","Ola"],
    "Electronics": ["Croma","Reliance Digital","Vijay Sales"],
    "Bill Payment": ["Tata Power","BSES Electricity","Airtel Broadband"],
    "Mobile Recharge": ["Jio Recharge","Airtel Recharge","Vi Recharge"],
    "Pharmacy": ["Apollo Pharmacy","1mg","Netmeds"],
    "Fashion": ["Myntra","Ajio","Flipkart Fashion"],
    "Entertainment": ["BookMyShow","PVR Cinemas","Netflix"],
    "Education": ["BYJU'S","Unacademy","Vedantu"],
    "Insurance": ["LIC Premium","HDFC Life","ICICI Prudential"]
}

DEVICE_TYPES = ["Android","iOS","Web"]
TXN_TYPES_WEIGHTED = ["P2M"]*5 + ["P2P"]*3 + ["Bill Payment"]*1 + ["Recharge"]*1


def random_date_in_range(start, end):
    delta = end - start
    return start + timedelta(seconds=random.randint(0, int(delta.total_seconds())))


def build_users(n=2000):
    users = []
    signup_start = datetime(2022, 1, 1)
    signup_end = datetime(2025, 12, 31)
    for uid in range(1, n + 1):
        name = f"{random.choice(INDIAN_FIRST_NAMES)} {random.choice(INDIAN_LAST_NAMES)}"
        age = random.randint(18, 60)
        city, state = random.choice(CITIES_STATES)
        acc_type = random.choices(["Savings", "Current"], weights=[85, 15])[0]
        signup = random_date_in_range(signup_start, signup_end).date().isoformat()
        kyc = random.choices([1, 0], weights=[96, 4])[0]
        users.append((uid, name, age, city, state, acc_type, signup, kyc))
    return users


def build_banks():
    return [(i + 1, b, f"BNK{i+1:03d}") for i, b in enumerate(BANKS)]


def build_merchants(n=200):
    merchants = []
    mid = 1
    for _ in range(n):
        category = random.choice(MERCHANT_CATEGORIES)
        name = random.choice(MERCHANT_NAMES[category])
        city, _ = random.choice(CITIES_STATES)
        merchants.append((mid, name, category, city))
        mid += 1
    return merchants


def build_transactions(users, merchants, banks, n=15000):
    transactions = []
    txn_id = 1
    start = datetime(2025, 1, 1)
    end = datetime(2026, 6, 30)

    user_home_city = {u[0]: u[3] for u in users}
    bank_ids = [b[0] for b in banks]
    merchant_ids = [m[0] for m in merchants]
    user_ids = [u[0] for u in users]

    # ---- 1. NORMAL TRANSACTIONS ----
    normal_count = int(n * 0.94)
    for _ in range(normal_count):
        uid = random.choice(user_ids)
        home_city = user_home_city[uid]
        txn_type = random.choice(TXN_TYPES_WEIGHTED)
        merchant_id = random.choice(merchant_ids) if txn_type in ("P2M", "Bill Payment", "Recharge") else None
        amount = round(random.uniform(20, 8000), 2)
        ts = random_date_in_range(start, end)
        # keep it to normal daytime hours mostly
        ts = ts.replace(hour=random.choices(range(24), weights=[1]*6+[4]*12+[2]*6)[0])
        status = random.choices(["SUCCESS", "FAILED", "PENDING"], weights=[92, 6, 2])[0]
        device = random.choice(DEVICE_TYPES)
        transactions.append((txn_id, uid, merchant_id, random.choice(bank_ids), amount,
                              ts.strftime("%Y-%m-%d %H:%M:%S"), txn_type, status, device, home_city))
        txn_id += 1

    # ---- 2. VELOCITY FRAUD PATTERN (bot-like burst) ----
    fraud_users_velocity = random.sample(user_ids, 12)
    for uid in fraud_users_velocity:
        base_ts = random_date_in_range(start, end)
        burst_size = random.randint(6, 10)
        for i in range(burst_size):
            ts = base_ts + timedelta(seconds=random.randint(5, 20) * i)
            amount = round(random.uniform(500, 3000), 2)
            transactions.append((txn_id, uid, random.choice(merchant_ids), random.choice(bank_ids),
                                  amount, ts.strftime("%Y-%m-%d %H:%M:%S"), "P2M", "SUCCESS",
                                  random.choice(DEVICE_TYPES), user_home_city[uid]))
            txn_id += 1

    # ---- 3. ODD-HOUR HIGH-VALUE PATTERN ----
    fraud_users_oddhour = random.sample(user_ids, 15)
    for uid in fraud_users_oddhour:
        ts = random_date_in_range(start, end).replace(hour=random.randint(1, 4))
        amount = round(random.uniform(25000, 90000), 2)
        transactions.append((txn_id, uid, random.choice(merchant_ids), random.choice(bank_ids),
                              amount, ts.strftime("%Y-%m-%d %H:%M:%S"), "P2P", "SUCCESS",
                              random.choice(DEVICE_TYPES), user_home_city[uid]))
        txn_id += 1

    # ---- 4. FAILED-RETRY BURST (testing pattern) ----
    fraud_users_retry = random.sample(user_ids, 10)
    for uid in fraud_users_retry:
        base_ts = random_date_in_range(start, end)
        amount = round(random.uniform(1, 50), 2)  # small test amounts
        merchant = random.choice(merchant_ids)
        attempts = random.randint(4, 7)
        for i in range(attempts):
            ts = base_ts + timedelta(seconds=30 * i)
            status = "FAILED" if i < attempts - 1 else "SUCCESS"
            transactions.append((txn_id, uid, merchant, random.choice(bank_ids), amount,
                                  ts.strftime("%Y-%m-%d %H:%M:%S"), "P2M", status,
                                  random.choice(DEVICE_TYPES), user_home_city[uid]))
            txn_id += 1

    # ---- 5. GEO-MISMATCH / IMPOSSIBLE TRAVEL ----
    fraud_users_geo = random.sample(user_ids, 10)
    for uid in fraud_users_geo:
        home_city = user_home_city[uid]
        other_city = random.choice([c for c, _ in CITIES_STATES if c != home_city])
        day = random_date_in_range(start, end)
        ts1 = day.replace(hour=10, minute=random.randint(0, 59))
        ts2 = day.replace(hour=11, minute=random.randint(0, 59))  # 1 hour later, different city
        amount1 = round(random.uniform(200, 2000), 2)
        amount2 = round(random.uniform(200, 2000), 2)
        transactions.append((txn_id, uid, random.choice(merchant_ids), random.choice(bank_ids),
                              amount1, ts1.strftime("%Y-%m-%d %H:%M:%S"), "P2M", "SUCCESS",
                              random.choice(DEVICE_TYPES), home_city))
        txn_id += 1
        transactions.append((txn_id, uid, random.choice(merchant_ids), random.choice(bank_ids),
                              amount2, ts2.strftime("%Y-%m-%d %H:%M:%S"), "P2M", "SUCCESS",
                              random.choice(DEVICE_TYPES), other_city))
        txn_id += 1

    return transactions


def main():
    conn = sqlite3.connect(DB_PATH)
    cur = conn.cursor()

    with open(SCHEMA_PATH, "r") as f:
        cur.executescript(f.read())

    users = build_users()
    banks = build_banks()
    merchants = build_merchants()
    transactions = build_transactions(users, merchants, banks)

    cur.executemany("INSERT INTO users VALUES (?,?,?,?,?,?,?,?)", users)
    cur.executemany("INSERT INTO banks VALUES (?,?,?)", banks)
    cur.executemany("INSERT INTO merchants VALUES (?,?,?,?)", merchants)
    cur.executemany("INSERT INTO transactions VALUES (?,?,?,?,?,?,?,?,?,?)", transactions)

    conn.commit()

    print(f"Users inserted:        {len(users)}")
    print(f"Banks inserted:        {len(banks)}")
    print(f"Merchants inserted:    {len(merchants)}")
    print(f"Transactions inserted: {len(transactions)}")
    print(f"Database written to:  {DB_PATH}")

    conn.close()


if __name__ == "__main__":
    main()
