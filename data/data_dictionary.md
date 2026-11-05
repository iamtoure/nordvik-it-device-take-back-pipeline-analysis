# Data Dictionary — Nordvik IT – Device Take-Back Pipeline

**Business context:** Synthetic dataset modeling an IT asset take-back and circularity
operation. Devices are received from B2B customers 
(small and medium-sized businesses [SMB] and Large Corporate and Public [LCP] segments), 
processed through a warehouse pipeline, and either resold as refurbished, recycled, or disposed.

**Schema shape:** Four dimension tables (`warehouses`, `device_categories`, `customers`,
`devices`) and two fact tables at different grains (`pipeline_events` — one row per
stage transition; `outcomes` — one row per device, final result).

---

## 1. `warehouses` — Dimension

**Grain:** one row per processing warehouse. **Primary key:** `warehouse_id`.

| Field | Type | Description | Notes |
|---|---|---|---|
| warehouse_id | int | Unique identifier for the warehouse | Primary key |
| city | text | City where the warehouse is located | Stockholm, Oslo, Helsinki, or Copenhagen |
| country | text | Country of the warehouse | |
| manager_name | text | Name of the warehouse manager | **Noise field** — not needed for core analysis |
| phone | text | Warehouse contact phone number | **Noise field** |
| address | text | Street address of the warehouse | **Noise field** |

---

## 2. `device_categories` — Dimension

**Grain:** one row per device category. **Primary key:** `category_id`.

| Field | Type | Description | Notes |
|---|---|---|---|
| category_id | int | Unique identifier for the category | Primary key |
| category_name | text | Category label (Laptop, Monitor, Desktop, Phone, Tablet, Peripheral) | |
| avg_retail_value | int | Baseline retail value used to derive listing/sale prices | Reference value, not a real observed price |
| category_description | text | Short marketing-style description of the category | **Noise field** — descriptive only |

---

## 3. `customers` — Dimension

**Grain:** one row per B2B customer account. **Primary key:** `customer_id`.

| Field | Type | Description | Notes |
|---|---|---|---|
| customer_id | int | Unique identifier for the customer | Primary key |
| customer_name | text | Business/company name | |
| segment | text | Customer segment | `LCP` (large corporate/public sector) or `SMB` — ~70/30 split |
| country | text | Customer's country | Sweden, Norway, Finland, or Denmark |
| address | text | Customer's registered address | **Noise field**, locale-matched to country |
| phone | text | Customer contact phone | **Noise field**, locale-matched to country |
| email | text | Customer contact email | **Noise field** |

---

## 4. `devices` — Dimension

**Grain:** one row per physical device (take-back unit). **Primary key:** `device_id`.

| Field | Type | Description | Notes |
|---|---|---|---|
| device_id | int | Unique identifier for the device | Primary key |
| customer_id | int | Customer who sent the device in | Foreign key → `customers.customer_id` |
| category_id | int | Device category | Foreign key → `device_categories.category_id` |
| warehouse_id | int | Warehouse processing the device | Foreign key → `warehouses.warehouse_id` |
| brand | text | Manufacturer brand | Matched realistically to category |
| model | text | Specific model | Matched realistically to brand + category |
| serial_number | text | Device serial number | **Noise field** — looks important, not needed for workflow analysis |
| notes | text | Free-text handling note (mostly blank) | **Noise field** |
| intake_date | date | Date the device was received | Seasonal weighting (higher Jan–Feb, Sep) |

---

## 5. `pipeline_events` — Fact (event grain)

**Grain:** one row per stage transition per device (a device has multiple rows).
**Primary key:** `event_id`.

| Field | Type | Description | Notes |
|---|---|---|---|
| event_id | int | Unique identifier for this event row | Primary key — surrogate, not business-meaningful |
| device_id | int | Device this event belongs to | Foreign key → `devices.device_id` |
| stage | text | Pipeline stage reached at this event | `received`, `data_wipe_security_check`, `graded`, `refurbished`, `listed`, `sold` (last two only apply to reusable devices) |
| event_timestamp | datetime | Timestamp the device reached this stage | Duration between stages is derived, not stored directly |
| handled_by_employee | text | Staff member who logged the event | **Noise field** — drawn from a fixed pool of 30 names |

**Known bottlenecks deliberately built into this table (for exception analysis):**
- Warehouse `2` (Oslo) runs ~1.8x slower than other warehouses specifically at the `graded` stage
- Category `4` (Phone) runs ~2x slower than other categories specifically at `data_wipe_security_check`
- Time-on-market (`listed` → `sold`) follows a long-tailed distribution — most items sell reasonably fast, but a meaningful minority take far longer or never sell

---

## 6. `outcomes` — Fact (device grain)

**Grain:** one row per device — the final result of its journey. **Primary key:** `device_id`.

| Field | Type | Description | Notes |
|---|---|---|---|
| device_id | int | Device this outcome belongs to | Foreign key → `devices.device_id` (also the primary key here, 1:1 with devices) |
| final_status | text | How the device's journey ended | `sold`, `unsold_written_off`, `recycled`, or `disposed` |
| listed_price | float | Price the device was listed at | Null for `recycled`/`disposed` (never reached listing) |
| sale_price | float | Price the device sold for | Null unless `final_status = sold` |
| sale_date | datetime | Date/time of sale | Null unless `final_status = sold` |
| shipping_carrier | text | Carrier used to ship the sold item | **Noise field** — only populated when `final_status = sold` |

---

## Table relationships (for schema/ERD reference)

```
customers ──┐
            │
warehouses ─┼──► devices ──┬──► pipeline_events   (one device : many events)
            │              │
categories ─┘              └──► outcomes           (one device : one outcome)
```
