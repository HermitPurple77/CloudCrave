-- =============================================================
--  CloudCrave Analytics Command Center — PostgreSQL Schema
--  Powers: Dashboard, Brands, Orders, Expenses, Analytics,
--          Reports, Alerts, Settings pages
-- =============================================================

-- ─────────────────────────────────────────────
--  EXTENSIONS
-- ─────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";  -- fast ILIKE search on orders/brands


-- ─────────────────────────────────────────────
--  ENUMS
-- ─────────────────────────────────────────────
CREATE TYPE platform_type   AS ENUM ('Swiggy', 'Zomato', 'Direct');
CREATE TYPE order_status    AS ENUM ('Pending', 'Processing', 'Delivered', 'Cancelled');
CREATE TYPE brand_status    AS ENUM ('Active', 'Paused', 'Archived');
CREATE TYPE expense_category AS ENUM ('Ingredients', 'Platform Fee', 'Packaging', 'Labour', 'Marketing', 'Other');
CREATE TYPE report_format   AS ENUM ('PDF', 'Excel', 'CSV');
CREATE TYPE alert_severity  AS ENUM ('critical', 'warning', 'info', 'success');
CREATE TYPE user_role       AS ENUM ('Admin', 'Manager', 'Viewer');


-- =============================================================
--  CORE TABLES
-- =============================================================

-- ─────────────────────────────────────────────
--  USERS  (Settings page → Profile)
-- ─────────────────────────────────────────────
CREATE TABLE users (
    id            UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
    full_name     VARCHAR(120)  NOT NULL,
    email         VARCHAR(255)  NOT NULL UNIQUE,
    phone         VARCHAR(20),
    role          user_role     NOT NULL DEFAULT 'Viewer',
    avatar_initials CHAR(3),                     -- e.g. 'AK'
    created_at    TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

-- ─────────────────────────────────────────────
--  USER NOTIFICATION PREFERENCES  (Settings → Notifications)
-- ─────────────────────────────────────────────
CREATE TABLE user_notification_preferences (
    user_id                UUID     PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    revenue_alerts         BOOLEAN  NOT NULL DEFAULT TRUE,
    order_spike_alerts     BOOLEAN  NOT NULL DEFAULT TRUE,
    weekly_report_email    BOOLEAN  NOT NULL DEFAULT FALSE,
    inventory_alerts       BOOLEAN  NOT NULL DEFAULT TRUE,
    updated_at             TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─────────────────────────────────────────────
--  INTEGRATIONS  (Settings → Integrations)
-- ─────────────────────────────────────────────
CREATE TABLE integrations (
    id           UUID         PRIMARY KEY DEFAULT uuid_generate_v4(),
    name         VARCHAR(80)  NOT NULL UNIQUE,   -- 'Swiggy API', 'Zomato API', 'Google Sheets Export'
    is_enabled   BOOLEAN      NOT NULL DEFAULT FALSE,
    api_key      TEXT,                           -- store encrypted in practice
    last_synced  TIMESTAMPTZ,
    updated_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);


-- ─────────────────────────────────────────────
--  BRANDS  (Brands page)
-- ─────────────────────────────────────────────
CREATE TABLE brands (
    id            UUID         PRIMARY KEY DEFAULT uuid_generate_v4(),
    name          VARCHAR(80)  NOT NULL UNIQUE,   -- 'Wrapz', 'BowlCo', etc.
    category      VARCHAR(80),                    -- 'Wraps & Rolls', 'Pizza', …
    color_hex     CHAR(7),                        -- '#f5a623' — used for charts
    status        brand_status NOT NULL DEFAULT 'Active',
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- Which platforms a brand is listed on (many-to-many via junction)
CREATE TABLE brand_platforms (
    brand_id  UUID          NOT NULL REFERENCES brands(id) ON DELETE CASCADE,
    platform  platform_type NOT NULL,
    PRIMARY KEY (brand_id, platform)
);


-- ─────────────────────────────────────────────
--  MENU ITEMS  (referenced by order_items)
-- ─────────────────────────────────────────────
CREATE TABLE menu_items (
    id          UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
    brand_id    UUID          NOT NULL REFERENCES brands(id) ON DELETE CASCADE,
    name        VARCHAR(120)  NOT NULL,
    price       NUMERIC(10,2) NOT NULL CHECK (price >= 0),
    is_active   BOOLEAN       NOT NULL DEFAULT TRUE,
    created_at  TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);


-- ─────────────────────────────────────────────
--  CUSTOMERS  (Orders page → Customer column)
-- ─────────────────────────────────────────────
CREATE TABLE customers (
    id          UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
    name        VARCHAR(120)  NOT NULL,
    phone       VARCHAR(20),
    email       VARCHAR(255),
    created_at  TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);


-- ─────────────────────────────────────────────
--  ORDERS  (Orders page)
-- ─────────────────────────────────────────────
CREATE TABLE orders (
    id              UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
    order_ref       VARCHAR(20)   NOT NULL UNIQUE,    -- '#ORD-8841'
    brand_id        UUID          NOT NULL REFERENCES brands(id),
    customer_id     UUID          REFERENCES customers(id),
    platform        platform_type NOT NULL,
    total_amount    NUMERIC(10,2) NOT NULL CHECK (total_amount >= 0),
    status          order_status  NOT NULL DEFAULT 'Pending',
    ordered_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    delivered_at    TIMESTAMPTZ,
    cancellation_reason TEXT
);

-- Line items per order
CREATE TABLE order_items (
    id           UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
    order_id     UUID          NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
    menu_item_id UUID          NOT NULL REFERENCES menu_items(id),
    quantity     SMALLINT      NOT NULL DEFAULT 1 CHECK (quantity > 0),
    unit_price   NUMERIC(10,2) NOT NULL CHECK (unit_price >= 0)
);


-- ─────────────────────────────────────────────
--  EXPENSES  (Expenses page)
-- ─────────────────────────────────────────────
CREATE TABLE expenses (
    id           UUID              PRIMARY KEY DEFAULT uuid_generate_v4(),
    brand_id     UUID              REFERENCES brands(id),   -- NULL = shared/all brands
    category     expense_category  NOT NULL,
    description  VARCHAR(255)      NOT NULL,
    amount       NUMERIC(10,2)     NOT NULL CHECK (amount >= 0),
    expense_date DATE              NOT NULL DEFAULT CURRENT_DATE,
    created_by   UUID              REFERENCES users(id),
    created_at   TIMESTAMPTZ       NOT NULL DEFAULT NOW()
);


-- ─────────────────────────────────────────────
--  DAILY REVENUE SNAPSHOTS  (Dashboard KPIs, Analytics charts)
--  Pre-aggregated once per day per brand × platform for fast reads
-- ─────────────────────────────────────────────
CREATE TABLE daily_revenue_snapshots (
    id              UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
    snapshot_date   DATE          NOT NULL,
    brand_id        UUID          NOT NULL REFERENCES brands(id),
    platform        platform_type NOT NULL,
    total_revenue   NUMERIC(12,2) NOT NULL DEFAULT 0,
    total_orders    INTEGER       NOT NULL DEFAULT 0,
    delivered_count INTEGER       NOT NULL DEFAULT 0,
    cancelled_count INTEGER       NOT NULL DEFAULT 0,
    avg_order_value NUMERIC(10,2) GENERATED ALWAYS AS (
        CASE WHEN total_orders > 0
             THEN ROUND(total_revenue / total_orders, 2)
             ELSE 0 END
    ) STORED,
    UNIQUE (snapshot_date, brand_id, platform)
);


-- ─────────────────────────────────────────────
--  HOURLY ORDER COUNTS  (Analytics → "Orders by Hour" chart)
-- ─────────────────────────────────────────────
CREATE TABLE hourly_order_stats (
    id           UUID    PRIMARY KEY DEFAULT uuid_generate_v4(),
    stat_date    DATE    NOT NULL,
    hour_of_day  SMALLINT NOT NULL CHECK (hour_of_day BETWEEN 0 AND 23),
    order_count  INTEGER NOT NULL DEFAULT 0,
    UNIQUE (stat_date, hour_of_day)
);


-- ─────────────────────────────────────────────
--  INVENTORY  (Alerts → "Inventory low" notifications)
-- ─────────────────────────────────────────────
CREATE TABLE inventory (
    id                UUID         PRIMARY KEY DEFAULT uuid_generate_v4(),
    brand_id          UUID         NOT NULL REFERENCES brands(id),
    ingredient_name   VARCHAR(120) NOT NULL,
    current_stock     INTEGER      NOT NULL DEFAULT 0,   -- in servings/units
    low_stock_threshold INTEGER    NOT NULL DEFAULT 50,
    unit              VARCHAR(30)  NOT NULL DEFAULT 'servings',
    updated_at        TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    UNIQUE (brand_id, ingredient_name)
);


-- ─────────────────────────────────────────────
--  ALERTS  (Alerts page)
-- ─────────────────────────────────────────────
CREATE TABLE alerts (
    id          UUID           PRIMARY KEY DEFAULT uuid_generate_v4(),
    severity    alert_severity NOT NULL DEFAULT 'info',
    title       VARCHAR(120)   NOT NULL,
    body        TEXT           NOT NULL,
    brand_id    UUID           REFERENCES brands(id),   -- NULL = system-wide
    is_read     BOOLEAN        NOT NULL DEFAULT FALSE,
    created_at  TIMESTAMPTZ    NOT NULL DEFAULT NOW()
);


-- ─────────────────────────────────────────────
--  REPORTS  (Reports page)
-- ─────────────────────────────────────────────
CREATE TABLE reports (
    id            UUID           PRIMARY KEY DEFAULT uuid_generate_v4(),
    name          VARCHAR(200)   NOT NULL,
    format        report_format  NOT NULL,
    brand_scope   VARCHAR(80),                   -- 'All Brands', '6 Brands', brand name, etc.
    platform_scope VARCHAR(80),                  -- 'All Platforms', 'Swiggy, Zomato', etc.
    file_size_kb  INTEGER,
    file_path     TEXT,                           -- S3 key or local path
    generated_at  TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
    generated_by  UUID           REFERENCES users(id),
    is_scheduled  BOOLEAN        NOT NULL DEFAULT FALSE,
    schedule_cron VARCHAR(60)                     -- e.g. '0 6 1 * *' for monthly
);


-- =============================================================
--  INDEXES  (for the dashboard's live read patterns)
-- =============================================================

-- Orders: search by ref, brand, platform, status, date
CREATE INDEX idx_orders_brand_id      ON orders (brand_id);
CREATE INDEX idx_orders_platform      ON orders (platform);
CREATE INDEX idx_orders_status        ON orders (status);
CREATE INDEX idx_orders_ordered_at    ON orders (ordered_at DESC);
CREATE INDEX idx_orders_order_ref     ON orders USING gin (order_ref gin_trgm_ops);

-- Expenses: filter by brand, category, date range
CREATE INDEX idx_expenses_brand_id    ON expenses (brand_id);
CREATE INDEX idx_expenses_category    ON expenses (category);
CREATE INDEX idx_expenses_date        ON expenses (expense_date DESC);

-- Daily snapshots: fast dashboard aggregation
CREATE INDEX idx_snapshots_date       ON daily_revenue_snapshots (snapshot_date DESC);
CREATE INDEX idx_snapshots_brand      ON daily_revenue_snapshots (brand_id, snapshot_date DESC);

-- Alerts: unread first
CREATE INDEX idx_alerts_unread        ON alerts (is_read, created_at DESC);

-- Inventory: low-stock check
CREATE INDEX idx_inventory_brand      ON inventory (brand_id);


-- =============================================================
--  VIEWS  (power the dashboard KPI cards directly)
-- =============================================================

-- Dashboard → "Total Revenue / Orders / Avg Order Value / Cancellations"
-- Pass :start_date and :end_date from your backend
CREATE VIEW vw_dashboard_kpis AS
SELECT
    SUM(total_revenue)                              AS total_revenue,
    SUM(total_orders)                               AS total_orders,
    SUM(cancelled_count)                            AS total_cancelled,
    ROUND(SUM(total_revenue) / NULLIF(SUM(total_orders), 0), 2) AS avg_order_value
FROM daily_revenue_snapshots;

-- Dashboard → "Top Brands by Revenue Share"
CREATE VIEW vw_brand_revenue_share AS
SELECT
    b.id,
    b.name,
    b.color_hex,
    SUM(s.total_revenue)   AS revenue,
    SUM(s.total_orders)    AS orders,
    ROUND(
        100.0 * SUM(s.total_revenue) /
        NULLIF(SUM(SUM(s.total_revenue)) OVER (), 0),
    1)                     AS revenue_share_pct
FROM daily_revenue_snapshots s
JOIN brands b ON b.id = s.brand_id
GROUP BY b.id, b.name, b.color_hex
ORDER BY revenue DESC;

-- Dashboard → Platform split pie chart
CREATE VIEW vw_platform_revenue_split AS
SELECT
    platform,
    SUM(total_revenue)  AS revenue,
    ROUND(
        100.0 * SUM(total_revenue) /
        NULLIF(SUM(SUM(total_revenue)) OVER (), 0),
    1) AS pct
FROM daily_revenue_snapshots
GROUP BY platform
ORDER BY revenue DESC;

-- Expenses page → category breakdown
CREATE VIEW vw_expense_breakdown AS
SELECT
    category,
    SUM(amount)  AS total_amount,
    ROUND(
        100.0 * SUM(amount) /
        NULLIF(SUM(SUM(amount)) OVER (), 0),
    1) AS pct
FROM expenses
GROUP BY category
ORDER BY total_amount DESC;

-- Inventory alerts
CREATE VIEW vw_low_stock_items AS
SELECT
    i.id,
    b.name   AS brand_name,
    i.ingredient_name,
    i.current_stock,
    i.low_stock_threshold,
    i.unit
FROM inventory i
JOIN brands b ON b.id = i.brand_id
WHERE i.current_stock <= i.low_stock_threshold
ORDER BY i.current_stock ASC;


-- =============================================================
--  SEED DATA  (matches what the dashboard currently shows)
-- =============================================================

-- Users
INSERT INTO users (id, full_name, email, phone, role, avatar_initials) VALUES
    ('00000000-0000-0000-0000-000000000001', 'Arjun Kumar', 'arjun@cloudcrave.in', '+91 98765 43210', 'Admin', 'AK');

INSERT INTO user_notification_preferences (user_id, revenue_alerts, order_spike_alerts, weekly_report_email, inventory_alerts)
VALUES ('00000000-0000-0000-0000-000000000001', TRUE, TRUE, FALSE, TRUE);

-- Integrations
INSERT INTO integrations (name, is_enabled) VALUES
    ('Swiggy API',           TRUE),
    ('Zomato API',           TRUE),
    ('Google Sheets Export', FALSE);

-- Brands
INSERT INTO brands (id, name, category, color_hex, status) VALUES
    ('10000000-0000-0000-0000-000000000001', 'Wrapz',   'Wraps & Rolls',  '#f5a623', 'Active'),
    ('10000000-0000-0000-0000-000000000002', 'BowlCo',  'Healthy Bowls',  '#e05c3a', 'Active'),
    ('10000000-0000-0000-0000-000000000003', 'PizzaX',  'Pizza',          '#5cb87a', 'Active'),
    ('10000000-0000-0000-0000-000000000004', 'NoodleZ', 'Asian Noodles',  '#6a7fa8', 'Paused'),
    ('10000000-0000-0000-0000-000000000005', 'Burger+', 'Burgers',        '#b08adc', 'Active'),
    ('10000000-0000-0000-0000-000000000006', 'SushiGo', 'Japanese',       '#4db8c8', 'Active');

INSERT INTO brand_platforms (brand_id, platform) VALUES
    ('10000000-0000-0000-0000-000000000001', 'Swiggy'),
    ('10000000-0000-0000-0000-000000000001', 'Zomato'),
    ('10000000-0000-0000-0000-000000000002', 'Swiggy'),
    ('10000000-0000-0000-0000-000000000002', 'Direct'),
    ('10000000-0000-0000-0000-000000000003', 'Zomato'),
    ('10000000-0000-0000-0000-000000000004', 'Swiggy'),
    ('10000000-0000-0000-0000-000000000005', 'Zomato'),
    ('10000000-0000-0000-0000-000000000005', 'Direct'),
    ('10000000-0000-0000-0000-000000000006', 'Swiggy');

-- Customers
INSERT INTO customers (id, name) VALUES
    ('20000000-0000-0000-0000-000000000001', 'Riya Sharma'),
    ('20000000-0000-0000-0000-000000000002', 'Karan Mehta'),
    ('20000000-0000-0000-0000-000000000003', 'Priya Nair'),
    ('20000000-0000-0000-0000-000000000004', 'Amit Verma'),
    ('20000000-0000-0000-0000-000000000005', 'Sneha Das'),
    ('20000000-0000-0000-0000-000000000006', 'Rohit Pillai'),
    ('20000000-0000-0000-0000-000000000007', 'Meena Joshi');

-- Orders (from the Orders page table)
INSERT INTO orders (order_ref, brand_id, customer_id, platform, total_amount, status, ordered_at) VALUES
    ('#ORD-8841', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', 'Swiggy',  480, 'Delivered',  NOW() - INTERVAL '28 min'),
    ('#ORD-8840', '10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000002', 'Direct',  310, 'Processing', NOW() - INTERVAL '40 min'),
    ('#ORD-8839', '10000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000003', 'Zomato',  650, 'Delivered',  NOW() - INTERVAL '55 min'),
    ('#ORD-8838', '10000000-0000-0000-0000-000000000004', '20000000-0000-0000-0000-000000000004', 'Swiggy',  290, 'Pending',    NOW() - INTERVAL '72 min'),
    ('#ORD-8837', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000005', 'Zomato',  220, 'Cancelled',  NOW() - INTERVAL '85 min'),
    ('#ORD-8836', '10000000-0000-0000-0000-000000000005', '20000000-0000-0000-0000-000000000006', 'Swiggy',  380, 'Delivered',  NOW() - INTERVAL '100 min'),
    ('#ORD-8835', '10000000-0000-0000-0000-000000000006', '20000000-0000-0000-0000-000000000007', 'Swiggy',  540, 'Delivered',  NOW() - INTERVAL '118 min');

-- Expenses (from the Expenses page)
INSERT INTO expenses (brand_id, category, description, amount, expense_date) VALUES
    ('10000000-0000-0000-0000-000000000003', 'Ingredients',  'Tomato & Cheese Stock',     4200, CURRENT_DATE),
    (NULL,                                   'Platform Fee', 'Swiggy Commission Apr',      9100, CURRENT_DATE),
    ('10000000-0000-0000-0000-000000000003', 'Packaging',    'Eco-friendly Boxes x500',   2800, CURRENT_DATE),
    (NULL,                                   'Labour',       'Part-time kitchen staff',    3500, CURRENT_DATE),
    (NULL,                                   'Marketing',    'Zomato Ad Campaign',         1500, CURRENT_DATE);

-- Daily snapshots (Apr 2026 summary, one row per brand for quick KPI reads)
INSERT INTO daily_revenue_snapshots (snapshot_date, brand_id, platform, total_revenue, total_orders, delivered_count, cancelled_count) VALUES
    ('2026-04-22', '10000000-0000-0000-0000-000000000001', 'Swiggy', 12000, 520, 490, 30),
    ('2026-04-22', '10000000-0000-0000-0000-000000000001', 'Zomato', 11400, 504, 480, 24),
    ('2026-04-22', '10000000-0000-0000-0000-000000000002', 'Swiggy', 10500, 430, 410, 20),
    ('2026-04-22', '10000000-0000-0000-0000-000000000002', 'Direct',  8600, 413, 400, 13),
    ('2026-04-22', '10000000-0000-0000-0000-000000000003', 'Zomato', 14800, 612, 590, 22),
    ('2026-04-22', '10000000-0000-0000-0000-000000000004', 'Swiggy', 13200, 558, 520, 38),
    ('2026-04-22', '10000000-0000-0000-0000-000000000005', 'Zomato',  5100, 200, 190, 10),
    ('2026-04-22', '10000000-0000-0000-0000-000000000005', 'Direct',  3500, 201, 195,  6),
    ('2026-04-22', '10000000-0000-0000-0000-000000000006', 'Swiggy',  5500, 241, 230, 11);

-- Hourly order stats (today's peak hours for Analytics chart)
INSERT INTO hourly_order_stats (stat_date, hour_of_day, order_count) VALUES
    (CURRENT_DATE,  9,  8),
    (CURRENT_DATE, 10, 14),
    (CURRENT_DATE, 11, 22),
    (CURRENT_DATE, 12, 41),
    (CURRENT_DATE, 13, 52),
    (CURRENT_DATE, 14, 38),
    (CURRENT_DATE, 15, 27),
    (CURRENT_DATE, 16, 15),
    (CURRENT_DATE, 17,  9);

-- Inventory (NoodleZ low-stock alert from Alerts page)
INSERT INTO inventory (brand_id, ingredient_name, current_stock, low_stock_threshold, unit) VALUES
    ('10000000-0000-0000-0000-000000000004', 'Wheat Noodle', 40, 50, 'servings'),
    ('10000000-0000-0000-0000-000000000003', 'Mozzarella',  120, 80, 'servings'),
    ('10000000-0000-0000-0000-000000000001', 'Tortilla',    210, 100, 'pieces');

-- Alerts
INSERT INTO alerts (severity, title, body, brand_id, is_read) VALUES
    ('critical', 'Revenue dip detected',   'BowlCo revenue dropped 18% vs last Tuesday. Possible platform outage on Direct channel.',     '10000000-0000-0000-0000-000000000002', FALSE),
    ('warning',  'High cancellation rate', 'Wrapz has 12% cancellation today, above 8% threshold. Review order prep time.',              '10000000-0000-0000-0000-000000000001', FALSE),
    ('warning',  'Inventory low',          'NoodleZ: wheat noodle stock critically low (~40 servings). Restock today.',                   '10000000-0000-0000-0000-000000000004', FALSE),
    ('success',  'Milestone reached 🎉',   'PizzaX crossed ₹50,000 total revenue this month for the first time!',                        '10000000-0000-0000-0000-000000000003', FALSE),
    ('info',     'Scheduled report ready', 'Q1 2026 Brand Performance Report is generated. Download it in Reports.',                      NULL,                                   FALSE);

-- Reports
INSERT INTO reports (name, format, brand_scope, platform_scope, file_size_kb, generated_at, is_scheduled) VALUES
    ('Monthly Revenue Summary — April 2026',  'PDF',   'All Brands', 'All Platforms',          248, '2026-04-22 00:00:00+05:30', FALSE),
    ('Brand Performance Report — Q1 2026',    'Excel', '6 Brands',   'All Platforms',          1126, '2026-04-01 00:00:00+05:30', TRUE),
    ('Orders Audit Log — March 2026',         'CSV',   'All Brands', 'All Platforms',           560, '2026-03-31 23:59:00+05:30', FALSE),
    ('Expense Breakdown — March 2026',        'PDF',   'All Brands', 'All Categories',          184, '2026-03-31 23:59:00+05:30', FALSE),
    ('Platform ROI Analysis — Q1 2026',       'PDF',   'All Brands', 'Swiggy, Zomato, Direct',  390, '2026-04-05 06:00:00+05:30', TRUE);


-- =============================================================
--  USEFUL QUERIES FOR THE DASHBOARD
-- =============================================================

-- [1] Dashboard KPIs for a date range
--   SELECT * FROM vw_dashboard_kpis;
--   (add WHERE snapshot_date BETWEEN '2026-04-01' AND '2026-04-22' for ranges)

-- [2] Top brands by revenue share
--   SELECT * FROM vw_brand_revenue_share LIMIT 6;

-- [3] Platform split
--   SELECT * FROM vw_platform_revenue_split;

-- [4] Recent orders with brand + customer name
--   SELECT o.order_ref, c.name AS customer, b.name AS brand,
--          o.platform, o.total_amount, o.status, o.ordered_at
--   FROM orders o
--   JOIN brands b ON b.id = o.brand_id
--   LEFT JOIN customers c ON c.id = o.customer_id
--   ORDER BY o.ordered_at DESC
--   LIMIT 50;

-- [5] Expense breakdown this month
--   SELECT * FROM vw_expense_breakdown;

-- [6] Low stock items (trigger inventory alert)
--   SELECT * FROM vw_low_stock_items;

-- [7] Unread alerts
--   SELECT * FROM alerts WHERE is_read = FALSE ORDER BY created_at DESC;

-- [8] Revenue + profit trend (Analytics → Monthly Revenue vs Profit)
--   SELECT DATE_TRUNC('month', snapshot_date) AS month,
--          SUM(total_revenue) AS revenue,
--          SUM(total_revenue) * 0.28 AS estimated_profit   -- replace with real margin
--   FROM daily_revenue_snapshots
--   GROUP BY 1 ORDER BY 1;
