-- ============================================================
-- Project   : UPI Transactions & Fraud Pattern Analytics
-- File      : schema.sql
-- Author    : Mahendar Reddy Maram
-- Purpose   : Database schema for a UPI (Unified Payments
--             Interface) style digital payments platform.
--             Modeled after real-world Indian fintech systems
--             (PhonePe / GPay / Paytm style transaction flow).
-- Engine    : SQLite (portable). Fully compatible with MySQL
--             with minor type changes (see NOTES at bottom).
-- ============================================================

DROP TABLE IF EXISTS transactions;
DROP TABLE IF EXISTS merchants;
DROP TABLE IF EXISTS banks;
DROP TABLE IF EXISTS users;

CREATE TABLE users (
    user_id         INTEGER PRIMARY KEY,
    full_name       TEXT NOT NULL,
    age             INTEGER,
    city            TEXT,
    state           TEXT,
    account_type    TEXT CHECK (account_type IN ('Savings','Current')),
    signup_date     DATE,
    kyc_verified    INTEGER DEFAULT 1        -- 1 = Yes, 0 = No
);

CREATE TABLE banks (
    bank_id         INTEGER PRIMARY KEY,
    bank_name       TEXT NOT NULL,
    ifsc_prefix     TEXT
);

CREATE TABLE merchants (
    merchant_id     INTEGER PRIMARY KEY,
    merchant_name   TEXT NOT NULL,
    category        TEXT,                    -- Grocery, Fuel, Travel, Food, Bills, etc.
    city             TEXT
);

CREATE TABLE transactions (
    transaction_id      INTEGER PRIMARY KEY,
    user_id             INTEGER NOT NULL,
    merchant_id         INTEGER,              -- NULL for P2P transfers
    bank_id             INTEGER NOT NULL,
    amount              REAL NOT NULL,
    txn_timestamp       DATETIME NOT NULL,
    transaction_type    TEXT CHECK (transaction_type IN ('P2P','P2M','Bill Payment','Recharge')),
    status              TEXT CHECK (status IN ('SUCCESS','FAILED','PENDING')),
    device_type         TEXT CHECK (device_type IN ('Android','iOS','Web')),
    city                TEXT,
    FOREIGN KEY (user_id) REFERENCES users(user_id),
    FOREIGN KEY (merchant_id) REFERENCES merchants(merchant_id),
    FOREIGN KEY (bank_id) REFERENCES banks(bank_id)
);

CREATE INDEX idx_txn_user ON transactions(user_id);
CREATE INDEX idx_txn_timestamp ON transactions(txn_timestamp);
CREATE INDEX idx_txn_status ON transactions(status);

-- ============================================================
-- NOTES for MySQL portability:
--   - Replace INTEGER PRIMARY KEY with INT AUTO_INCREMENT PRIMARY KEY
--   - Replace DATETIME literal handling as needed (MySQL DATETIME is native)
--   - CHECK constraints are enforced in MySQL 8.0.16+; use ENUM as an
--     alternative for older versions.
-- ============================================================
