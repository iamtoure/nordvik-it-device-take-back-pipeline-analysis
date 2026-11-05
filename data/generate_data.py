"""
Synthetic data generator: Nordvik IT – Device Take-Back Pipeline.

Produces raw CSVs for: warehouses, device_categories, customers, devices,
pipeline_events, outcomes -- then applies a separate "corruption pass" to
inject realistic data-quality issues on top of the clean data.

Run: python3 generate_data.py
Output: ./output/*.csv (clean) and ./output_messy/*.csv (messy versions)
"""

import random
import numpy as np
import pandas as pd
from faker import Faker
from datetime import datetime, timedelta
import os

# ---------------------------------------------------------------------------
# CONFIG
# ---------------------------------------------------------------------------
SEED = 42
random.seed(SEED)
np.random.seed(SEED)
fake = Faker()
Faker.seed(SEED)

# locale-specific generators so addresses/phones match the stated country
FAKE_BY_COUNTRY = {
    "Sweden": Faker("sv_SE"),
    "Norway": Faker("no_NO"),
    "Finland": Faker("fi_FI"),
    "Denmark": Faker("da_DK"),
}
for _f in FAKE_BY_COUNTRY.values():
    _f.seed_instance(SEED)

N_CUSTOMERS = 200
N_DEVICES = 6000
START_DATE = datetime(2025, 1, 1)
END_DATE = datetime(2025, 12, 31)
OUTPUT_DIR = "./output"
os.makedirs(OUTPUT_DIR, exist_ok=True)

WAREHOUSES = [
    {"warehouse_id": 1, "city": "Stockholm", "country": "Sweden"},
    {"warehouse_id": 2, "city": "Oslo", "country": "Norway"},
    {"warehouse_id": 3, "city": "Helsinki", "country": "Finland"},
    {"warehouse_id": 4, "city": "Copenhagen", "country": "Denmark"},
]

CATEGORY_DESCRIPTIONS = {
    1: "Portable computing devices including notebooks and ultrabooks.",
    2: "Standalone display units for desktop and workstation setups.",
    3: "Fixed workstation computers for office and home use.",
    4: "Mobile handsets including smartphones and feature phones.",
    5: "Slate-format touchscreen computing devices.",
    6: "Accessories and add-on hardware such as mice, keyboards, and docks.",
}

# baseline stage durations (days) per category: (mean, sigma) for lognormal draws
CATEGORIES = [
    {"category_id": 1, "category_name": "Laptop",     "avg_retail_value": 9000},
    {"category_id": 2, "category_name": "Monitor",     "avg_retail_value": 2500},
    {"category_id": 3, "category_name": "Desktop",     "avg_retail_value": 7000},
    {"category_id": 4, "category_name": "Phone",       "avg_retail_value": 4500},
    {"category_id": 5, "category_name": "Tablet",      "avg_retail_value": 4000},
    {"category_id": 6, "category_name": "Peripheral",  "avg_retail_value": 500},
]

STAGES = [
    "received",
    "data_wipe_security_check",
    "graded",
    "refurbished",       # only for reusable branch
    "listed",            # only for reusable branch
    "sold",              # or unsold_written_off
]

# Which warehouse runs structurally slower, and at which stage (the "mess")
SLOW_WAREHOUSE_ID = 2       # Oslo
SLOW_WAREHOUSE_STAGE = "graded"
SLOW_WAREHOUSE_MULTIPLIER = 1.8

SLOW_CATEGORY_ID = 4        # Phone
SLOW_CATEGORY_STAGE = "data_wipe_security_check"
SLOW_CATEGORY_MULTIPLIER = 2.0

REUSABLE_PROBABILITY = 0.78   # overall probability a device is graded reusable
WRITE_OFF_DAYS_THRESHOLD = 60  # days sitting as "listed" before written off

# noise fields: a fixed pool of staff names (more realistic than a fresh name
# per event -- a real warehouse has a limited headcount logging events)
EMPLOYEE_POOL = [fake.name() for _ in range(30)]
SHIPPING_CARRIERS = ["PostNord", "DHL", "Bring", "Schenker"]


def random_date(start, end):
    delta = end - start
    days = (delta.days)
    offset = random.randint(0, days)
    d = start + timedelta(days=offset)
    return d


def seasonal_intake_date():
    """Weighted intake date: heavier in Jan-Feb and Sep (post budget-cycle refresh)."""
    weights_by_month = {1: 2.2, 2: 1.8, 3: 1.0, 4: 0.9, 5: 0.9, 6: 0.8,
                         7: 0.6, 8: 0.8, 9: 1.6, 10: 1.1, 11: 1.0, 12: 1.3}
    months = list(weights_by_month.keys())
    weights = list(weights_by_month.values())
    month = random.choices(months, weights=weights, k=1)[0]
    day = random.randint(1, 28)
    return datetime(2025, month, day)


def generate_customers(n):
    rows = []
    countries = ["Sweden", "Norway", "Finland", "Denmark"]
    for cid in range(1, n + 1):
        segment = "LCP" if random.random() < 0.70 else "SMB"
        country = random.choice(countries)
        local_fake = FAKE_BY_COUNTRY[country]
        rows.append({
            "customer_id": cid,
            "customer_name": fake.company(),
            "segment": segment,
            "country": country,
            "address": local_fake.address().replace("\n", ", "),
            "phone": local_fake.phone_number(),
            "email": fake.company_email(),
        })
    return pd.DataFrame(rows)


def stage_duration_days(warehouse_id, category_id, stage):
    """Draw a right-skewed (lognormal) duration in days for moving through `stage`,
    with deliberate multipliers for the slow warehouse/category combos."""
    # 'sold' represents time-on-market: needs a much heavier tail than internal
    # processing stages, so that a genuine fraction of items cross the write-off
    # threshold rather than always selling quickly.
    if stage == "sold":
        base_mean = 12.0
        sigma = 1.1
    else:
        base_mean = 2.0
        sigma = 0.6

    multiplier = 1.0
    if warehouse_id == SLOW_WAREHOUSE_ID and stage == SLOW_WAREHOUSE_STAGE:
        multiplier *= SLOW_WAREHOUSE_MULTIPLIER
    if category_id == SLOW_CATEGORY_ID and stage == SLOW_CATEGORY_STAGE:
        multiplier *= SLOW_CATEGORY_MULTIPLIER

    draw = np.random.lognormal(mean=np.log(base_mean), sigma=sigma)
    return max(0.1, draw * multiplier)


def generate_pipeline_and_outcomes(devices_df):
    event_rows = []
    outcome_rows = []

    for _, dev in devices_df.iterrows():
        did = dev["device_id"]
        wid = dev["warehouse_id"]
        cid = dev["category_id"]
        t = dev["intake_date"]

        # received
        event_rows.append({"device_id": did, "stage": "received", "event_timestamp": t,
                            "handled_by_employee": random.choice(EMPLOYEE_POOL)})

        # data_wipe_security_check
        t = t + timedelta(days=stage_duration_days(wid, cid, "data_wipe_security_check"))
        event_rows.append({"device_id": did, "stage": "data_wipe_security_check", "event_timestamp": t,
                            "handled_by_employee": random.choice(EMPLOYEE_POOL)})

        # graded
        t = t + timedelta(days=stage_duration_days(wid, cid, "graded"))
        event_rows.append({"device_id": did, "stage": "graded", "event_timestamp": t,
                            "handled_by_employee": random.choice(EMPLOYEE_POOL)})

        is_reusable = random.random() < REUSABLE_PROBABILITY

        if not is_reusable:
            final_status = random.choices(["recycled", "disposed"], weights=[0.7, 0.3], k=1)[0]
            outcome_rows.append({
                "device_id": did, "final_status": final_status,
                "listed_price": None, "sale_price": None, "sale_date": None,
                "shipping_carrier": None,
            })
            continue

        # refurbished
        t = t + timedelta(days=stage_duration_days(wid, cid, "refurbished"))
        event_rows.append({"device_id": did, "stage": "refurbished", "event_timestamp": t,
                            "handled_by_employee": random.choice(EMPLOYEE_POOL)})

        # listed
        t = t + timedelta(days=stage_duration_days(wid, cid, "listed"))
        event_rows.append({"device_id": did, "stage": "listed", "event_timestamp": t,
                            "handled_by_employee": random.choice(EMPLOYEE_POOL)})

        category = next(c for c in CATEGORIES if c["category_id"] == cid)
        listed_price = round(category["avg_retail_value"] * np.random.uniform(0.25, 0.5), 2)

        time_on_market = stage_duration_days(wid, cid, "sold")
        if time_on_market > WRITE_OFF_DAYS_THRESHOLD:
            outcome_rows.append({
                "device_id": did, "final_status": "unsold_written_off",
                "listed_price": listed_price, "sale_price": None, "sale_date": None,
                "shipping_carrier": None,
            })
        else:
            sale_t = t + timedelta(days=time_on_market)
            event_rows.append({"device_id": did, "stage": "sold", "event_timestamp": sale_t,
                                "handled_by_employee": random.choice(EMPLOYEE_POOL)})
            sale_price = round(listed_price * np.random.uniform(0.85, 1.05), 2)
            outcome_rows.append({
                "device_id": did, "final_status": "sold",
                "listed_price": listed_price, "sale_price": sale_price, "sale_date": sale_t,
                "shipping_carrier": random.choice(SHIPPING_CARRIERS),
            })

    events_df = pd.DataFrame(event_rows)
    events_df.insert(0, "event_id", range(1, len(events_df) + 1))
    return events_df, pd.DataFrame(outcome_rows)


MESSY_DIR = "./output_messy"
os.makedirs(MESSY_DIR, exist_ok=True)
MESSY_RATE = 0.03  # ~3% affected rows per issue type -- tune as needed


def corrupt_devices(devices_df, warehouses_df):
    """Structural issues (SQL-side): duplicate rows, orphaned warehouse_id,
    null category_id. Presentation issue (Power Query-side): blank brand."""
    df = devices_df.copy()

    # duplicate ~3% of rows (simulates a re-submitted intake batch)
    dup_ids = df.sample(frac=MESSY_RATE, random_state=1).index
    df = pd.concat([df, df.loc[dup_ids]], ignore_index=True)

    # orphaned warehouse_id: point ~1% of rows at a warehouse_id that doesn't exist
    bad_wh_ids = df.sample(frac=0.01, random_state=2).index
    df.loc[bad_wh_ids, "warehouse_id"] = 99

    # null category_id on ~1% of rows (should never be null -> SQL must catch)
    null_cat_ids = df.sample(frac=0.01, random_state=3).index
    df.loc[null_cat_ids, "category_id"] = None

    # blank/missing brand on ~4% of rows (Power Query-side: cosmetic, not correctness)
    blank_brand_ids = df.sample(frac=0.04, random_state=4).index
    df.loc[blank_brand_ids, "brand"] = ""

    return df


def corrupt_pipeline_events(events_df, devices_df):
    """Structural issues (SQL-side): duplicate rows (same content, but each
    gets its own new event_id -- simulating a re-logged event, not a raw
    primary-key collision), event_timestamp before the device's own
    intake_date (a logical impossibility)."""
    df = events_df.copy()

    dup_ids = df.sample(frac=MESSY_RATE, random_state=5).index
    dup_rows = df.loc[dup_ids].copy()
    df = pd.concat([df, dup_rows], ignore_index=True)
    max_id = df["event_id"].max()
    # give the appended duplicate rows fresh, unique event_ids
    new_id_start = max_id + 1
    df.loc[df.index[-len(dup_rows):], "event_id"] = range(new_id_start, new_id_start + len(dup_rows))

    intake_lookup = devices_df.set_index("device_id")["intake_date"]
    bad_ts_ids = df.sample(frac=0.01, random_state=6).index
    for idx in bad_ts_ids:
        did = df.at[idx, "device_id"]
        if did in intake_lookup.index:
            df.at[idx, "event_timestamp"] = pd.to_datetime(intake_lookup[did]) - timedelta(days=5)

    return df


def corrupt_customers(customers_df):
    """Structural issue (SQL-side): inconsistent casing/whitespace on segment
    (an enum-like column -> should be standardized before it's trusted).
    Presentation issue (Power Query-side): country name variants."""
    df = customers_df.copy()

    segment_variant_ids = df.sample(frac=0.03, random_state=7).index
    variants = {"LCP": ["lcp", "Lcp ", " LCP"], "SMB": ["smb", "Smb ", " SMB"]}
    for idx in segment_variant_ids:
        seg = df.at[idx, "segment"]
        df.at[idx, "segment"] = random.choice(variants.get(seg, [seg]))

    country_variant_map = {
        "Sweden": ["SE", "Sverige", "sweden"],
        "Norway": ["NO", "Norge", "norway"],
        "Finland": ["FI", "Suomi", "finland"],
        "Denmark": ["DK", "Danmark", "denmark"],
    }
    country_variant_ids = df.sample(frac=0.05, random_state=8).index
    for idx in country_variant_ids:
        country = df.at[idx, "country"]
        if country in country_variant_map:
            df.at[idx, "country"] = random.choice(country_variant_map[country])

    return df


def corrupt_outcomes(outcomes_df):
    """Presentation issue (Power Query-side): a subset of sale_price values
    exported as text with a currency suffix, mixing types in the column."""
    df = outcomes_df.copy()
    df["sale_price"] = df["sale_price"].astype(object)
    sold_ids = df[df["final_status"] == "sold"].sample(frac=0.05, random_state=9).index
    for idx in sold_ids:
        price = df.at[idx, "sale_price"]
        df.at[idx, "sale_price"] = f"{price:.0f} kr"
    return df


BRANDS_BY_CATEGORY = {
    1: ["Dell", "HP", "Lenovo", "Apple", "Asus"],                # Laptop
    2: ["Dell", "LG", "Samsung", "BenQ", "AOC"],                 # Monitor
    3: ["Dell", "HP", "Lenovo", "Fujitsu"],                      # Desktop
    4: ["Apple", "Samsung", "Google", "Nokia", "OnePlus"],       # Phone
    5: ["Apple", "Samsung", "Lenovo", "Huawei"],                 # Tablet
    6: ["Logitech", "Microsoft", "HP", "Jabra"],                 # Peripheral
}


MODELS_BY_CATEGORY_BRAND = {
    1: {  # Laptop
        "Dell": ["Latitude 5420", "XPS 13", "Inspiron 15"],
        "HP": ["EliteBook 840", "ProBook 450", "Pavilion 15"],
        "Lenovo": ["ThinkPad T14", "IdeaPad 5", "ThinkPad X1 Carbon"],
        "Apple": ["MacBook Air M1", "MacBook Pro 14"],
        "Asus": ["ZenBook 14", "VivoBook 15"],
    },
    2: {  # Monitor
        "Dell": ["P2419H", "U2720Q"],
        "LG": ["27UL850", "24MK430H"],
        "Samsung": ["Odyssey G5", "S24R350"],
        "BenQ": ["GW2480", "PD2700U"],
        "AOC": ["24B1XH", "27B1H"],
    },
    3: {  # Desktop
        "Dell": ["OptiPlex 7090", "Precision 3660"],
        "HP": ["EliteDesk 800", "ProDesk 400"],
        "Lenovo": ["ThinkCentre M720", "IdeaCentre 5"],
        "Fujitsu": ["Esprimo D758", "Esprimo P757"],
    },
    4: {  # Phone
        "Apple": ["iPhone 12", "iPhone 13", "iPhone SE"],
        "Samsung": ["Galaxy S21", "Galaxy A52"],
        "Google": ["Pixel 6", "Pixel 5"],
        "Nokia": ["Nokia 8.3", "Nokia G20"],
        "OnePlus": ["OnePlus 9", "OnePlus Nord"],
    },
    5: {  # Tablet
        "Apple": ["iPad Air", "iPad Pro 11"],
        "Samsung": ["Galaxy Tab S7", "Galaxy Tab A8"],
        "Lenovo": ["Tab M10", "Tab P11"],
        "Huawei": ["MatePad 11", "MatePad Pro"],
    },
    6: {  # Peripheral
        "Logitech": ["MX Master 3", "K380 Keyboard"],
        "Microsoft": ["Surface Mouse", "Modern Keyboard"],
        "HP": ["USB-C Dock", "Wireless Mouse 220"],
        "Jabra": ["Evolve 65", "Speak 750"],
    },
}


def generate_devices(n, customers_df):
    rows = []
    customer_ids = customers_df["customer_id"].tolist()
    for did in range(1, n + 1):
        category = random.choice(CATEGORIES)
        cat_id = category["category_id"]
        brand = random.choice(BRANDS_BY_CATEGORY[cat_id])
        model = random.choice(MODELS_BY_CATEGORY_BRAND[cat_id][brand])
        # notes: mostly blank, ~8% have a free-text handling note (irrelevant noise)
        notes = fake.sentence(nb_words=8) if random.random() < 0.08 else ""
        rows.append({
            "device_id": did,
            "customer_id": random.choice(customer_ids),
            "category_id": cat_id,
            "warehouse_id": random.choice(WAREHOUSES)["warehouse_id"],
            "brand": brand,
            "model": model,
            "serial_number": fake.bothify(text="SN-????-######").upper(),
            "notes": notes,
            "intake_date": seasonal_intake_date(),
        })
    return pd.DataFrame(rows)


def main():
    warehouses_df = pd.DataFrame(WAREHOUSES)
    warehouses_df["manager_name"] = [fake.name() for _ in range(len(warehouses_df))]
    warehouses_df["phone"] = [FAKE_BY_COUNTRY[c].phone_number() for c in warehouses_df["country"]]
    warehouses_df["address"] = [FAKE_BY_COUNTRY[c].street_address() for c in warehouses_df["country"]]

    categories_df = pd.DataFrame(CATEGORIES)
    categories_df["category_description"] = categories_df["category_id"].map(CATEGORY_DESCRIPTIONS)

    customers_df = generate_customers(N_CUSTOMERS)
    devices_df = generate_devices(N_DEVICES, customers_df)
    pipeline_events_df, outcomes_df = generate_pipeline_and_outcomes(devices_df)

    warehouses_df.to_csv(f"{OUTPUT_DIR}/warehouses.csv", index=False)
    categories_df.to_csv(f"{OUTPUT_DIR}/device_categories.csv", index=False)
    customers_df.to_csv(f"{OUTPUT_DIR}/customers.csv", index=False)
    devices_df.to_csv(f"{OUTPUT_DIR}/devices.csv", index=False)
    pipeline_events_df.to_csv(f"{OUTPUT_DIR}/pipeline_events.csv", index=False)
    outcomes_df.to_csv(f"{OUTPUT_DIR}/outcomes.csv", index=False)

    # --- messy versions ---
    messy_devices_df = corrupt_devices(devices_df, warehouses_df)
    messy_events_df = corrupt_pipeline_events(pipeline_events_df, devices_df)
    messy_customers_df = corrupt_customers(customers_df)
    messy_outcomes_df = corrupt_outcomes(outcomes_df)

    warehouses_df.to_csv(f"{MESSY_DIR}/warehouses.csv", index=False)
    categories_df.to_csv(f"{MESSY_DIR}/device_categories.csv", index=False)
    messy_customers_df.to_csv(f"{MESSY_DIR}/customers.csv", index=False)
    messy_devices_df.to_csv(f"{MESSY_DIR}/devices.csv", index=False)
    messy_events_df.to_csv(f"{MESSY_DIR}/pipeline_events.csv", index=False)
    messy_outcomes_df.to_csv(f"{MESSY_DIR}/outcomes.csv", index=False)

    print()
    print(f"Messy dataset written to {MESSY_DIR}/  (row counts vs clean, due to duplicates):")
    print(f"  devices:         {len(messy_devices_df)}  (clean: {len(devices_df)})")
    print(f"  pipeline_events: {len(messy_events_df)}  (clean: {len(pipeline_events_df)})")

    print("Generated row counts:")
    print(f"  warehouses:      {len(warehouses_df)}")
    print(f"  categories:      {len(categories_df)}")
    print(f"  customers:       {len(customers_df)}  (LCP={sum(customers_df.segment=='LCP')}, SMB={sum(customers_df.segment=='SMB')})")
    print(f"  devices:         {len(devices_df)}")
    print(f"  pipeline_events: {len(pipeline_events_df)}")
    print(f"  outcomes:        {len(outcomes_df)}")
    print(outcomes_df['final_status'].value_counts())


if __name__ == "__main__":
    main()
