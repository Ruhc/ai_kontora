-- ============================================================
-- МегаБайт / МегаБайт — Synthetic DWH Starter DDL
-- Hackathon Week 1: Sales Mart dimensions & facts
-- PostgreSQL 14+
-- ============================================================

-- ---------------------- dim_store ----------------------
DROP TABLE IF EXISTS mart.dim_store CASCADE;
CREATE TABLE mart.dim_store (
    store_id    VARCHAR(8)   PRIMARY KEY,
    store_name  VARCHAR(120) NOT NULL,
    region      VARCHAR(60)  NOT NULL,
    city        VARCHAR(60)  NOT NULL,
    open_date   DATE         NOT NULL,
    is_active   BOOLEAN      NOT NULL DEFAULT TRUE
);

INSERT INTO mart.dim_store (store_id, store_name, region, city, open_date, is_active) VALUES
('M-104', 'МегаБайт Центральный',   'Москва',          'Москва',           '2019-06-15', TRUE),
('M-217', 'МегаБайт Невский',        'Северо-Запад',    'Санкт-Петербург',  '2020-02-01', TRUE),
('M-089', 'МегаБайт Левобережный',   'Сибирь',          'Новосибирск',      '2018-11-20', TRUE),
('M-312', 'МегаБайт Волжский',       'Поволжье',        'Казань',           '2021-08-10', TRUE),
('M-055', 'МегаБайт Южный',          'Юг',              'Краснодар',        '2022-01-05', TRUE);

-- ---------------------- dim_sku ------------------------
DROP TABLE IF EXISTS mart.dim_sku CASCADE;
CREATE TABLE mart.dim_sku (
    sku_id      SERIAL       PRIMARY KEY,
    sku_code    VARCHAR(20)  NOT NULL UNIQUE,
    sku_name    VARCHAR(120) NOT NULL,
    category    VARCHAR(60)  NOT NULL,
    unit_price  NUMERIC(10,2) NOT NULL
);

INSERT INTO mart.dim_sku (sku_id, sku_code, sku_name, category, unit_price) VALUES
(1, 'SKU-0011', 'Молоко 3.2% 1л',              'Молоко',           89.90),
(2, 'SKU-0024', 'Хлеб белый нарезной',          'Хлеб',            54.50),
(3, 'SKU-0037', 'Салат Цезарь 200г',            'Фреш',           189.00),
(4, 'SKU-0045', 'Кола 0.5л',                    'Напитки',          79.90),
(5, 'SKU-0058', 'Чипсы сырные 150г',            'Снеки',           129.90),
(6, 'SKU-0062', 'Средство для посуды 500мл',    'Бытовая химия',   149.00),
(7, 'SKU-0071', 'Шоколад тёмный 90г',           'Кондитерка',      119.90),
(8, 'SKU-0083', 'Пельмени домашние 900г',       'Замороженные',    349.00);

-- ---------------------- dim_calendar -------------------
DROP TABLE IF EXISTS mart.dim_calendar CASCADE;
CREATE TABLE mart.dim_calendar (
    calendar_date   DATE        PRIMARY KEY,
    day_of_week     SMALLINT    NOT NULL,  -- 1=Mon … 7=Sun
    day_name        VARCHAR(20) NOT NULL,
    month_num       SMALLINT    NOT NULL,
    month_name      VARCHAR(20) NOT NULL,
    year_num        SMALLINT    NOT NULL,
    is_workday      BOOLEAN     NOT NULL
);

-- Generate 60 days starting 2024-03-01
INSERT INTO mart.dim_calendar (calendar_date, day_of_week, day_name, month_num, month_name, year_num, is_workday)
SELECT
    d::date                                       AS calendar_date,
    EXTRACT(ISODOW FROM d)::smallint              AS day_of_week,
    TO_CHAR(d, 'Day')                             AS day_name,
    EXTRACT(MONTH FROM d)::smallint               AS month_num,
    TO_CHAR(d, 'Month')                           AS month_name,
    EXTRACT(YEAR FROM d)::smallint                AS year_num,
    CASE WHEN EXTRACT(ISODOW FROM d) <= 5
         THEN TRUE ELSE FALSE END                 AS is_workday
FROM generate_series('2024-03-01'::date,
                     '2024-04-29'::date,
                     '1 day'::interval) AS d;

-- ---------------------- fact_sales_daily ---------------
DROP TABLE IF EXISTS mart.fact_sales_daily CASCADE;
CREATE TABLE mart.fact_sales_daily (
    sale_date       DATE           NOT NULL REFERENCES mart.dim_calendar(calendar_date),
    store_id        VARCHAR(8)     NOT NULL REFERENCES mart.dim_store(store_id),
    sku_id          INT            NOT NULL REFERENCES mart.dim_sku(sku_id),
    gross_revenue   NUMERIC(12,2)  NOT NULL,
    net_revenue     NUMERIC(12,2)  NOT NULL,
    returns_amt     NUMERIC(12,2)  NOT NULL DEFAULT 0,
    receipt_count   INT            NOT NULL,
    PRIMARY KEY (sale_date, store_id, sku_id)
);

INSERT INTO mart.fact_sales_daily
    (sale_date, store_id, sku_id, gross_revenue, net_revenue, returns_amt, receipt_count) VALUES
-- 2024-03-01
('2024-03-01', 'M-104', 1,  12540.00, 11286.00,  254.00, 140),
('2024-03-01', 'M-104', 4,   8790.00,  7911.00,  180.00,  110),
('2024-03-01', 'M-217', 2,   6230.00,  5607.00,  120.00,  114),
('2024-03-01', 'M-089', 5,   4150.00,  3735.00,   85.00,   32),
('2024-03-01', 'M-312', 7,   3580.00,  3222.00,    0.00,   30),
-- 2024-03-02
('2024-03-02', 'M-104', 1,  13100.00, 11790.00,  310.00, 146),
('2024-03-02', 'M-055', 3,   9420.00,  8478.00,  190.00,   50),
('2024-03-02', 'M-217', 6,   5670.00,  5103.00,  110.00,   38),
('2024-03-02', 'M-312', 8,   7840.00,  7056.00,  160.00,   22),
('2024-03-02', 'M-089', 2,   4920.00,  4428.00,   95.00,   90),
-- 2024-03-05
('2024-03-05', 'M-104', 3,  11200.00, 10080.00,  230.00,   59),
('2024-03-05', 'M-104', 7,   6780.00,  6102.00,  140.00,   57),
('2024-03-05', 'M-217', 1,  10340.00,  9306.00,  200.00, 115),
('2024-03-05', 'M-055', 5,   3890.00,  3501.00,   80.00,   30),
('2024-03-05', 'M-312', 4,   5120.00,  4608.00,  105.00,   64),
-- 2024-03-10
('2024-03-10', 'M-089', 1,   9870.00,  8883.00,  195.00, 110),
('2024-03-10', 'M-104', 8,   8430.00,  7587.00,  170.00,   24),
('2024-03-10', 'M-217', 4,   7150.00,  6435.00,  145.00,   89),
('2024-03-10', 'M-055', 2,   5340.00,  4806.00,  105.00,   98),
('2024-03-10', 'M-312', 6,   4260.00,  3834.00,   85.00,   29),
-- 2024-03-15
('2024-03-15', 'M-104', 1,  14200.00, 12780.00,  290.00, 158),
('2024-03-15', 'M-217', 3,  10890.00,  9801.00,  220.00,   58),
('2024-03-15', 'M-089', 7,   5670.00,  5103.00,  115.00,   47),
('2024-03-15', 'M-312', 2,   4890.00,  4401.00,   95.00,   90),
('2024-03-15', 'M-055', 8,   6310.00,  5679.00,  130.00,   18),
-- 2024-03-20
('2024-03-20', 'M-104', 5,   7650.00,  6885.00,  155.00,   59),
('2024-03-20', 'M-217', 1,  11430.00, 10287.00,  230.00, 127),
('2024-03-20', 'M-089', 4,   6240.00,  5616.00,  125.00,   78),
('2024-03-20', 'M-312', 3,   8970.00,  8073.00,  180.00,   47),
('2024-03-20', 'M-055', 6,   3750.00,  3375.00,   75.00,   25);

-- ---------------------- fact_plan_monthly ---------------
DROP TABLE IF EXISTS mart.fact_plan_monthly CASCADE;
CREATE TABLE mart.fact_plan_monthly (
    plan_month      DATE           NOT NULL,  -- first day of month
    region          VARCHAR(60)    NOT NULL,
    category        VARCHAR(60)    NOT NULL,
    target_revenue  NUMERIC(14,2)  NOT NULL,
    target_qty      INT            NOT NULL,
    PRIMARY KEY (plan_month, region, category)
);

INSERT INTO mart.fact_plan_monthly
    (plan_month, region, category, target_revenue, target_qty) VALUES
('2024-03-01', 'Москва',       'Молоко',       450000.00, 5000),
('2024-03-01', 'Северо-Запад', 'Хлеб',         320000.00, 5900),
('2024-03-01', 'Сибирь',       'Снеки',        180000.00, 1400),
('2024-04-01', 'Москва',       'Молоко',       470000.00, 5200),
('2024-04-01', 'Поволжье',     'Кондитерка',   210000.00, 1750),
('2024-04-01', 'Юг',           'Замороженные',  290000.00,  830);

-- ============================================================
-- End of starter DDL
-- ============================================================
