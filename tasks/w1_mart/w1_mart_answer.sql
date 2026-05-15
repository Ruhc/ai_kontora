-- ============================================================
-- МегаБайт — Витрина план-факт анализа дневных продаж
-- Назначение: KPI-дашборд для Ирины Соколовой (COO) и операционных менеджеров
-- PostgreSQL 14+   |   Путь Б — синтетические данные
-- ============================================================

-- ДОПУЩЕНИЯ:
-- 1. Календарь: dim_calendar с заранее заполненными датами и флагом is_workday
-- 2. Timezone: все даты хранятся без TZ (UTC), дашборд отображает в МСК
-- 3. Тип дня для period_progress: РАБОЧИЕ дни (is_workday = TRUE)
--    Обоснование: месячные планы в МегаБайт формируются на кол-во рабочих дней пн-пт,
--    поэтому линейная интерполяция по рабочим дням точнее отражает ожидаемый темп.
-- 4. MTD (Month-To-Date): от начала месяца до MAX(sale_date) включительно
-- 5. Гранулярность плана: месяц × регион × категория
-- 6. Гранулярность факта: день × магазин × SKU → агрегируется до плановой гранулярности
-- 7. Активность магазинов: только is_active = TRUE (закрытые/приостановленные исключены)

-- СТРАТЕГИЯ ИНКРЕМЕНТАЛЬНОЙ ЗАГРУЗКИ:
-- fact_sales_daily:
--   MERGE по ключу (sale_date, store_id, sku_id)
--   Окно пересчёта — последние 3 дня: корректировки возвратов и сторно чеков
--   могут приходить с задержкой до 2 суток из POS M-104/M-217/M-089
-- fact_plan_monthly:
--   MERGE по ключу (plan_month, region, category)
--   Полная перезагрузка при получении нового Excel от коммерческого директора
-- dim_store / dim_sku:
--   SCD Type 1 (перезапись атрибутов); is_active обновляется немедленно
-- dim_calendar:
--   Статическая таблица, пересоздаётся 1 раз в год на следующий год

-- ============================================================
-- CTE 1: Обогащение продаж измерениями store, sku, calendar
-- ============================================================
WITH sales_daily_enriched AS (
    SELECT
        f.sale_date,
        c.year_num,
        c.month_num,
        DATE_TRUNC('month', f.sale_date)::DATE  AS sale_month,
        c.is_workday,
        s.region,
        s.store_id,
        s.store_name,
        s.city,
        sk.category,
        sk.sku_id,
        sk.sku_code,
        sk.sku_name,
        f.gross_revenue,
        f.net_revenue,
        f.returns_amt,
        f.receipt_count
    FROM mart.fact_sales_daily         f
    INNER JOIN mart.dim_calendar       c  ON f.sale_date  = c.calendar_date
    INNER JOIN mart.dim_store          s  ON f.store_id   = s.store_id
    INNER JOIN mart.dim_sku            sk ON f.sku_id     = sk.sku_id
    WHERE s.is_active = TRUE  -- закрытые магазины искажают сетевые средние
),

-- ============================================================
-- CTE 2: Агрегация факта день×магазин×SKU → месяц×регион×категория
-- ============================================================
sales_monthly_agg AS (
    SELECT
        sale_month,
        year_num,
        month_num,
        region,
        category,
        SUM(net_revenue)              AS actual_revenue_mtd,
        SUM(gross_revenue)            AS gross_revenue_mtd,
        SUM(returns_amt)              AS returns_amt_mtd,
        SUM(receipt_count)            AS receipt_count_mtd,
        COUNT(DISTINCT store_id)      AS stores_count,
        COUNT(DISTINCT sku_id)        AS sku_count,
        COUNT(DISTINCT sale_date)     AS days_with_sales
    FROM sales_daily_enriched
    GROUP BY sale_month, year_num, month_num, region, category
),

-- ============================================================
-- CTE 3: Доля прошедшего периода по РАБОЧИМ дням
-- Охватывает все месяцы в dim_calendar (в т.ч. будущие месяцы с планом без продаж)
-- ============================================================
period_progress AS (
    SELECT
        DATE_TRUNC('month', calendar_date)::DATE  AS period_month,
        COUNT(*) FILTER (WHERE is_workday)                                                  AS total_workdays_in_month,
        COUNT(*)                                                                             AS total_calendar_days_in_month,
        COUNT(*) FILTER (
            WHERE is_workday
              AND calendar_date <= (SELECT MAX(sale_date) FROM mart.fact_sales_daily)
        )                                                                                    AS elapsed_workdays_mtd,
        COUNT(*) FILTER (
            WHERE calendar_date <= (SELECT MAX(sale_date) FROM mart.fact_sales_daily)
        )                                                                                    AS elapsed_calendar_days_mtd,
        MAX(calendar_date) FILTER (
            WHERE calendar_date <= (SELECT MAX(sale_date) FROM mart.fact_sales_daily)
        )                                                                                    AS last_sale_date
    FROM mart.dim_calendar
    GROUP BY DATE_TRUNC('month', calendar_date)::DATE
),

-- ============================================================
-- CTE 4: FULL OUTER JOIN факта и плана
-- FULL OUTER — чтобы строки плана без продаж (напр. апрель 2024)
-- отображались в дашборде с нулевым фактом, а не терялись
-- ============================================================
plan_vs_actual AS (
    SELECT
        COALESCE(s.sale_month,  p.plan_month)                                   AS report_month,
        COALESCE(s.year_num,    EXTRACT(YEAR  FROM p.plan_month)::SMALLINT)     AS year_num,
        COALESCE(s.month_num,   EXTRACT(MONTH FROM p.plan_month)::SMALLINT)     AS month_num,
        COALESCE(s.region,      p.region)                                        AS region,
        COALESCE(s.category,    p.category)                                      AS category,

        -- Факт MTD
        COALESCE(s.actual_revenue_mtd,  0)  AS actual_revenue_mtd,
        COALESCE(s.gross_revenue_mtd,   0)  AS gross_revenue_mtd,
        COALESCE(s.returns_amt_mtd,     0)  AS returns_amt_mtd,
        COALESCE(s.receipt_count_mtd,   0)  AS receipt_count_mtd,
        COALESCE(s.stores_count,        0)  AS stores_count,
        COALESCE(s.sku_count,           0)  AS sku_count,
        COALESCE(s.days_with_sales,     0)  AS days_with_sales,

        -- План
        COALESCE(p.target_revenue, 0)       AS target_revenue_month,
        COALESCE(p.target_qty,     0)       AS target_qty_month,

        -- Прогресс периода (COALESCE 0 для будущих месяцев без продаж)
        COALESCE(pp.total_workdays_in_month,      0)  AS total_workdays_in_month,
        COALESCE(pp.elapsed_workdays_mtd,         0)  AS elapsed_workdays_mtd,
        COALESCE(pp.total_calendar_days_in_month, 0)  AS total_calendar_days_in_month,
        COALESCE(pp.elapsed_calendar_days_mtd,    0)  AS elapsed_calendar_days_mtd,
        pp.last_sale_date

    FROM sales_monthly_agg             s
    FULL OUTER JOIN mart.fact_plan_monthly p
        ON  s.sale_month = p.plan_month
        AND s.region     = p.region
        AND s.category   = p.category
    LEFT JOIN period_progress          pp
        ON COALESCE(s.sale_month, p.plan_month) = pp.period_month
),

-- ============================================================
-- CTE 5: Расчёт KPI-метрик план-факт
-- ============================================================
kpi_metrics AS (
    SELECT
        report_month,
        year_num,
        month_num,
        region,
        category,
        actual_revenue_mtd,
        gross_revenue_mtd,
        returns_amt_mtd,
        receipt_count_mtd,
        stores_count,
        sku_count,
        days_with_sales,
        target_revenue_month,
        target_qty_month,

        -- % прошедшего периода (рабочие дни)
        ROUND(
            CASE WHEN total_workdays_in_month > 0
                 THEN 100.0 * elapsed_workdays_mtd / total_workdays_in_month
                 ELSE 0 END, 2
        ) AS period_progress_pct,

        elapsed_workdays_mtd,
        total_workdays_in_month,
        elapsed_calendar_days_mtd,
        total_calendar_days_in_month,
        last_sale_date,

        -- Ожидаемая выручка MTD = план × доля рабочих дней
        ROUND(
            CASE WHEN total_workdays_in_month > 0
                 THEN target_revenue_month * elapsed_workdays_mtd / total_workdays_in_month
                 ELSE 0 END, 2
        ) AS expected_revenue_mtd,

        -- Отклонение факта от ожидаемого MTD
        ROUND(
            actual_revenue_mtd
            - CASE WHEN total_workdays_in_month > 0
                   THEN target_revenue_month * elapsed_workdays_mtd / total_workdays_in_month
                   ELSE 0 END, 2
        ) AS deviation_from_expected,

        -- Отклонение факта от полного планового месяца
        ROUND(actual_revenue_mtd - target_revenue_month, 2) AS deviation_from_target,

        -- % выполнения полного плана (для KPI-светофора)
        ROUND(
            CASE WHEN target_revenue_month > 0
                 THEN 100.0 * actual_revenue_mtd / target_revenue_month
                 ELSE NULL END, 2
        ) AS achievement_pct,

        -- % выполнения ожидаемого MTD (ключевая операционная метрика)
        ROUND(
            CASE WHEN total_workdays_in_month > 0 AND target_revenue_month > 0
                 THEN 100.0 * actual_revenue_mtd
                      / (target_revenue_month * elapsed_workdays_mtd / total_workdays_in_month)
                 ELSE NULL END, 2
        ) AS mtd_achievement_pct,

        -- Средний чек
        ROUND(
            CASE WHEN receipt_count_mtd > 0
                 THEN actual_revenue_mtd / receipt_count_mtd
                 ELSE NULL END, 2
        ) AS avg_receipt_value,

        -- % возвратов от валовой выручки
        ROUND(
            CASE WHEN gross_revenue_mtd > 0
                 THEN 100.0 * returns_amt_mtd / gross_revenue_mtd
                 ELSE NULL END, 2
        ) AS returns_pct

    FROM plan_vs_actual
),

-- ============================================================
-- CTE 6: Аналитика по SKU внутри категории (роль: категорийный менеджер)
-- ============================================================
category_analytics AS (
    SELECT
        sde.sale_month,
        sde.region,
        sde.category,
        sde.sku_code,
        sde.sku_name,
        SUM(sde.net_revenue)              AS sku_revenue_mtd,
        SUM(sde.receipt_count)            AS sku_receipt_count,
        SUM(sde.returns_amt)              AS sku_returns_amt,
        COUNT(DISTINCT sde.store_id)      AS stores_with_sku,
        COUNT(DISTINCT sde.sale_date)     AS days_with_sku_sales,
        ROUND(SUM(sde.net_revenue) / NULLIF(COUNT(DISTINCT sde.sale_date), 0), 2)
                                          AS avg_daily_revenue,
        -- Доля SKU в выручке категории
        ROUND(
            100.0 * SUM(sde.net_revenue)
            / NULLIF(SUM(SUM(sde.net_revenue))
                OVER (PARTITION BY sde.sale_month, sde.region, sde.category), 0),
            2
        )                                 AS sku_share_in_category_pct,
        -- Ранг по убыванию выручки (топ-SKU)
        RANK() OVER (
            PARTITION BY sde.sale_month, sde.region, sde.category
            ORDER BY SUM(sde.net_revenue) DESC
        )                                 AS sku_rank_top,
        -- Ранг по возрастанию выручки (аутсайдеры) — добавлен вместо корелированного подзапроса
        RANK() OVER (
            PARTITION BY sde.sale_month, sde.region, sde.category
            ORDER BY SUM(sde.net_revenue) ASC
        )                                 AS sku_rank_bottom
    FROM sales_daily_enriched sde
    GROUP BY sde.sale_month, sde.region, sde.category, sde.sku_code, sde.sku_name
),

-- ============================================================
-- CTE 7: Топ-3 и аутсайдеры по SKU в категории
-- Используем sku_rank_bottom <= 3 вместо self-referential подзапроса (невалидный PostgreSQL)
-- ============================================================
category_top_bottom AS (
    SELECT
        sale_month,
        region,
        category,
        STRING_AGG(
            sku_name || ' (' || TO_CHAR(sku_revenue_mtd, 'FM999,999,999') || ' ₽)',
            ', ' ORDER BY sku_rank_top
        ) FILTER (WHERE sku_rank_top    <= 3)   AS top_3_skus,
        STRING_AGG(
            sku_name || ' (' || TO_CHAR(sku_revenue_mtd, 'FM999,999,999') || ' ₽)',
            ', ' ORDER BY sku_rank_bottom
        ) FILTER (WHERE sku_rank_bottom <= 3)   AS bottom_3_skus,
        ROUND(AVG(sku_revenue_mtd), 2)          AS avg_sku_revenue,
        COUNT(DISTINCT sku_code)                AS total_skus_in_category
    FROM category_analytics
    GROUP BY sale_month, region, category
),

-- ============================================================
-- CTE 8: База для динамики — LAG вычисляется один раз
-- ============================================================
category_lag AS (
    SELECT
        report_month,
        region,
        category,
        actual_revenue_mtd,
        LAG(actual_revenue_mtd) OVER (
            PARTITION BY region, category
            ORDER BY report_month
        )   AS prev_month_revenue
    FROM kpi_metrics
),

-- ============================================================
-- CTE 9: Динамика категорий (МоМ)
-- ============================================================
category_dynamics AS (
    SELECT
        report_month,
        region,
        category,
        prev_month_revenue,
        ROUND(actual_revenue_mtd - COALESCE(prev_month_revenue, 0), 2)  AS revenue_change,
        ROUND(
            CASE WHEN COALESCE(prev_month_revenue, 0) > 0
                 THEN 100.0 * (actual_revenue_mtd - prev_month_revenue) / prev_month_revenue
                 ELSE NULL END, 2
        )   AS revenue_change_pct
    FROM category_lag
)

-- ============================================================
-- ФИНАЛЬНЫЙ SELECT: витрина для Direct Query (Power BI / Fine BI)
-- Все колонки имеют явные типы — Марина Чернова (BI-разработчик) не дорабатывает типы
-- ============================================================
SELECT
    -- Измерения
    km.report_month                         ::DATE          AS report_month,
    km.year_num                             ::SMALLINT      AS year_num,
    km.month_num                            ::SMALLINT      AS month_num,
    km.region                               ::VARCHAR(60)   AS region,
    km.category                             ::VARCHAR(60)   AS category,

    -- Факт MTD
    km.actual_revenue_mtd                   ::NUMERIC(14,2) AS actual_revenue_mtd,
    km.gross_revenue_mtd                    ::NUMERIC(14,2) AS gross_revenue_mtd,
    km.returns_amt_mtd                      ::NUMERIC(12,2) AS returns_amt_mtd,
    km.receipt_count_mtd                    ::INTEGER       AS receipt_count_mtd,
    km.stores_count                         ::INTEGER       AS stores_count,
    km.sku_count                            ::INTEGER       AS sku_count,
    km.days_with_sales                      ::INTEGER       AS days_with_sales,

    -- План
    km.target_revenue_month                 ::NUMERIC(14,2) AS target_revenue_month,
    km.target_qty_month                     ::INTEGER       AS target_qty_month,

    -- Прогресс периода
    km.period_progress_pct                  ::NUMERIC(5,2)  AS period_progress_pct,
    km.elapsed_workdays_mtd                 ::INTEGER       AS elapsed_workdays_mtd,
    km.total_workdays_in_month              ::INTEGER       AS total_workdays_in_month,
    km.elapsed_calendar_days_mtd            ::INTEGER       AS elapsed_calendar_days_mtd,
    km.total_calendar_days_in_month         ::INTEGER       AS total_calendar_days_in_month,
    km.last_sale_date                       ::DATE          AS last_sale_date,

    -- KPI план-факт
    km.expected_revenue_mtd                 ::NUMERIC(14,2) AS expected_revenue_mtd,
    km.deviation_from_expected              ::NUMERIC(14,2) AS deviation_from_expected,
    km.deviation_from_target                ::NUMERIC(14,2) AS deviation_from_target,
    km.achievement_pct                      ::NUMERIC(6,2)  AS achievement_pct,
    km.mtd_achievement_pct                  ::NUMERIC(6,2)  AS mtd_achievement_pct,

    -- Операционные метрики
    km.avg_receipt_value                    ::NUMERIC(10,2) AS avg_receipt_value,
    km.returns_pct                          ::NUMERIC(5,2)  AS returns_pct,

    -- Аналитика категорий (Роль BI)
    ctb.top_3_skus                          ::TEXT          AS top_3_skus,
    ctb.bottom_3_skus                       ::TEXT          AS bottom_3_skus,
    ctb.avg_sku_revenue                     ::NUMERIC(12,2) AS avg_sku_revenue,
    ctb.total_skus_in_category              ::INTEGER       AS total_skus_in_category,

    -- Динамика МоМ
    cd.prev_month_revenue                   ::NUMERIC(14,2) AS prev_month_revenue,
    cd.revenue_change                       ::NUMERIC(14,2) AS revenue_change,
    cd.revenue_change_pct                   ::NUMERIC(6,2)  AS revenue_change_pct,

    -- Статус светофора (>100% зелёный, 90-100% жёлтый, 70-90% оранжевый, <70% красный)
    CASE
        WHEN km.mtd_achievement_pct >= 100 THEN 'Выполнен'
        WHEN km.mtd_achievement_pct >=  90 THEN 'В норме'
        WHEN km.mtd_achievement_pct >=  70 THEN 'Внимание'
        WHEN km.mtd_achievement_pct IS NOT NULL THEN 'Критично'
        ELSE 'Нет данных'
    END                                     ::VARCHAR(20)   AS plan_status,

    -- Тренд МоМ
    CASE
        WHEN cd.revenue_change_pct >  10 THEN 'Сильный рост'
        WHEN cd.revenue_change_pct >   0 THEN 'Рост'
        WHEN cd.revenue_change_pct =   0 THEN 'Стабильно'
        WHEN cd.revenue_change_pct > -10 THEN 'Снижение'
        WHEN cd.revenue_change_pct IS NOT NULL THEN 'Сильное снижение'
        ELSE 'Нет данных'
    END                                     ::VARCHAR(20)   AS trend

FROM kpi_metrics km
LEFT JOIN category_top_bottom ctb
    ON  km.report_month = ctb.sale_month
    AND km.region       = ctb.region
    AND km.category     = ctb.category
LEFT JOIN category_dynamics cd
    ON  km.report_month = cd.report_month
    AND km.region       = cd.region
    AND km.category     = cd.category

ORDER BY
    km.report_month DESC,
    km.region,
    km.category;
