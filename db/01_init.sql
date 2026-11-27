-- Payment Chaos Lab schema and seed data.
-- The MariaDB container creates the `payments_lab` database and runs this file
-- only when the database volume is empty. Run `make reset` to re-seed.

CREATE TABLE merchants (
    id INT PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    api_token VARCHAR(100) NOT NULL,
    hmac_secret VARCHAR(100) NOT NULL,
    webhook_url VARCHAR(255) NOT NULL,
    commission_pct DECIMAL(5,2) NOT NULL
);

CREATE TABLE transactions (
    id INT AUTO_INCREMENT PRIMARY KEY,
    transaction_id VARCHAR(64) NOT NULL UNIQUE,
    merchant_id INT NOT NULL,
    order_id VARCHAR(64) NOT NULL,
    channel VARCHAR(32) NOT NULL,
    amount DECIMAL(12,2) NOT NULL,
    provider_fee DECIMAL(12,2) NULL,
    currency VARCHAR(8) NOT NULL,
    status ENUM('pending','success','failed') NOT NULL,
    error_code VARCHAR(64) NULL,
    created_at DATETIME NOT NULL COMMENT 'UTC timestamp',
    INDEX idx_m_created (merchant_id, created_at),
    INDEX idx_order (order_id),
    INDEX idx_status_created (status, created_at)
);

CREATE TABLE callbacks_log (
    id INT AUTO_INCREMENT PRIMARY KEY,
    transaction_id VARCHAR(64) NOT NULL,
    attempt INT NOT NULL DEFAULT 1,
    http_code INT NULL,
    response_body VARCHAR(255) NULL,
    sent_at DATETIME NOT NULL COMMENT 'UTC timestamp',
    INDEX idx_cb_trx (transaction_id),
    INDEX idx_cb_sent (sent_at)
);

CREATE TABLE provider_settlements (
    id INT AUTO_INCREMENT PRIMARY KEY,
    provider_tx_id VARCHAR(64) NOT NULL,
    external_ref VARCHAR(64) NOT NULL,
    channel VARCHAR(32) NOT NULL,
    gross_amount DECIMAL(12,2) NOT NULL,
    fee_amount DECIMAL(12,2) NOT NULL,
    net_amount DECIMAL(12,2) NOT NULL,
    provider_status VARCHAR(32) NOT NULL,
    settled_at_eat DATETIME NOT NULL COMMENT 'East Africa Time UTC+3',
    INDEX idx_settle_ref (external_ref),
    INDEX idx_settle_channel (channel)
);

-- Two merchants with deliberately fake credentials. Both webhooks point at the
-- local merchant simulator. Merchant 42 is the one the simulator uses.
INSERT INTO merchants VALUES
(42, 'Zoyk Retail Zambia', 'tok_zoyk_live_42', 'sec_zoyk_hmac', 'http://merchant:8001/webhook', 1.75),
(77, 'AvadaShop Kenya',    'tok_avada_live_77','sec_avada_hmac','http://merchant:8001/webhook', 2.00);

-- Seed transactions (UTC). Each row is a small investigation prompt:
--   trx_seed_002: success but provider_fee is NULL
--   trx_seed_003: webhook returned 500, then succeeded on retry
--   trx_seed_004: success but no callback row at all
--   trx_seed_005: still pending here, but the telco settled it
--   trx_seed_006: failed with TELCO_504
--   trx_seed_007/008: same order_id, one success and one duplicate failure
--   trx_seed_009: 22:30 UTC = 01:30 next day in UTC+3
INSERT INTO transactions (transaction_id, merchant_id, order_id, channel, amount, provider_fee, currency, status, error_code, created_at) VALUES
('trx_seed_001', 42, 'ord_1001', 'MTN_ZM',   500.00,  8.75, 'ZMW', 'success', NULL,          NOW() - INTERVAL 3 HOUR),
('trx_seed_002', 42, 'ord_1002', 'MTN_ZM',   250.00,  NULL, 'ZMW', 'success', NULL,          NOW() - INTERVAL 2 HOUR),
('trx_seed_003', 42, 'ord_1003', 'AIRTEL_ZM',300.00,  5.25, 'ZMW', 'success', NULL,          NOW() - INTERVAL 2 HOUR),
('trx_seed_004', 42, 'ord_1004', 'MTN_ZM',   150.00,  NULL, 'ZMW', 'success', NULL,          NOW() - INTERVAL 1 HOUR),
('trx_seed_005', 42, 'ord_1005', 'MTN_ZM',   400.00,  NULL, 'ZMW', 'pending', NULL,          NOW() - INTERVAL 1 HOUR),
('trx_seed_006', 42, 'ord_1006', 'AIRTEL_ZM',100.00,  NULL, 'ZMW', 'failed',  'TELCO_504',   NOW() - INTERVAL 40 MINUTE),
('trx_seed_007', 42, 'ord_dup_1', 'MTN_ZM',  200.00,  3.50, 'ZMW', 'success', NULL,          NOW() - INTERVAL 30 MINUTE),
('trx_seed_008', 42, 'ord_dup_1', 'MTN_ZM',  200.00,  NULL, 'ZMW', 'failed',  'DUP_ORDER',   NOW() - INTERVAL 29 MINUTE),
('trx_seed_009', 77, 'ord_ke_99','MPESA_KE',10000.00,175.00,'KES', 'success', NULL,          '2026-11-24 22:30:00');

INSERT INTO callbacks_log (transaction_id, attempt, http_code, response_body, sent_at) VALUES
('trx_seed_001', 1, 200, '{"result":"ok"}', NOW() - INTERVAL 3 HOUR),
('trx_seed_002', 1, 403, 'Cloudflare Block',NOW() - INTERVAL 2 HOUR),
('trx_seed_003', 1, 500, 'Internal Error',  NOW() - INTERVAL 2 HOUR),
('trx_seed_003', 2, 200, '{"result":"ok"}', NOW() - INTERVAL 118 MINUTE),
('trx_seed_009', 1, 200, '{"result":"ok"}', '2026-11-24 22:31:00');

INSERT INTO provider_settlements (provider_tx_id, external_ref, channel, gross_amount, fee_amount, net_amount, provider_status, settled_at_eat) VALUES
('prv_9001', 'trx_seed_001', 'MTN_ZM',    500.00,   8.75,  491.25, 'SUCCESS', DATE_ADD(NOW(), INTERVAL 3 HOUR)),
('prv_9005', 'trx_seed_005', 'MTN_ZM',    400.00,   7.00,  393.00, 'SUCCESS', DATE_ADD(NOW(), INTERVAL 3 HOUR)),
('prv_9009', 'trx_seed_009', 'MPESA_KE',10000.00, 175.00, 9825.00, 'SUCCESS', '2026-11-25 01:30:05');
