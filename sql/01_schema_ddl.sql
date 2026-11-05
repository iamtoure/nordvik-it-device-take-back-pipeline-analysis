/* =====================================================================
   01_schema_ddl.sql
   
   Nordvik IT - device take-back pipeline: production schema (MySQL)


   Design choices
   - Dimension foreign keys use ON DELETE RESTRICT, so an accidental
     delete fails loudly instead of cascading data loss.
   - pipeline_events and outcomes use ON DELETE CASCADE on device_id:
     they have no meaning without their parent device.
   - UNIQUE is used only for real-world invariants: devices.serial_number
     and customers.email. Address and phone are NOT unique (two
     businesses can share a building or a switchboard number).
   - employees starts at 9000 so employee IDs are easy to tell apart
     from other numeric IDs.
   ===================================================================== */

CREATE DATABASE IF NOT EXISTS device_pipeline;
USE device_pipeline;

-- ---------------------------------------------------------------------
-- Dimension tables
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS device_categories (
    category_id          INT AUTO_INCREMENT PRIMARY KEY,
    category_name        VARCHAR(50),
    avg_retail_value     INT,
    category_description VARCHAR(100)
);

CREATE TABLE IF NOT EXISTS warehouses (
    warehouse_id INT AUTO_INCREMENT PRIMARY KEY,
    city         VARCHAR(50),
    country      VARCHAR(50),
    manager_name VARCHAR(50),
    phone        VARCHAR(20),
    address      VARCHAR(50)
);

CREATE TABLE IF NOT EXISTS customers (
    customer_id   INT AUTO_INCREMENT PRIMARY KEY,
    customer_name VARCHAR(50),
    segment       VARCHAR(10),
    country       VARCHAR(50),
    address       VARCHAR(50),
    phone         VARCHAR(20),
    email         VARCHAR(50) UNIQUE
);

CREATE TABLE IF NOT EXISTS employees (
    emp_id   INT AUTO_INCREMENT PRIMARY KEY,
    emp_name VARCHAR(50)
) AUTO_INCREMENT = 9000;

-- ---------------------------------------------------------------------
-- Fact / detail tables
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS devices (
    device_id     INT AUTO_INCREMENT PRIMARY KEY,
    customer_id   INT,
    intake_date   DATE,
    category_id   INT,
    warehouse_id  INT,
    brand         VARCHAR(30),
    model         VARCHAR(30),
    serial_number VARCHAR(30) UNIQUE,
    notes         VARCHAR(30),
    CONSTRAINT fk_devices_customer
        FOREIGN KEY (customer_id)  REFERENCES customers(customer_id)           ON DELETE RESTRICT,
    CONSTRAINT fk_devices_category
        FOREIGN KEY (category_id)  REFERENCES device_categories(category_id)   ON DELETE RESTRICT,
    CONSTRAINT fk_devices_warehouse
        FOREIGN KEY (warehouse_id) REFERENCES warehouses(warehouse_id)         ON DELETE RESTRICT
);

CREATE TABLE IF NOT EXISTS pipeline_events (
    event_id        INT AUTO_INCREMENT PRIMARY KEY,
    device_id       INT,
    stage           VARCHAR(30),
    event_timestamp DATETIME,
    handled_by      INT,
    INDEX idx_events_device_stage (device_id, stage),
    CONSTRAINT fk_events_device
        FOREIGN KEY (device_id)  REFERENCES devices(device_id)   ON DELETE CASCADE,
    CONSTRAINT fk_events_employee
        FOREIGN KEY (handled_by) REFERENCES employees(emp_id)    ON DELETE RESTRICT
);

CREATE TABLE IF NOT EXISTS outcomes (
    device_id        INT PRIMARY KEY,
    final_status     VARCHAR(30),
    listed_price     DECIMAL(10,2),
    sale_price       DECIMAL(10,2),
    sale_date        DATETIME,
    shipping_carrier VARCHAR(30),
    CONSTRAINT fk_outcomes_device
        FOREIGN KEY (device_id) REFERENCES devices(device_id) ON DELETE CASCADE
);