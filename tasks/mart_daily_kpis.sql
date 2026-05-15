-- ============================================================
-- МегаБайт / Витрина данных для дашборда продаж
-- Назначение: План-факт анализ продаж с аналитикой для категорийного менеджера
-- PostgreSQL 14+
-- ============================================================

-- ДОПУЩЕНИЯ:
-- 1. Календарь: используется dim_calendar с предзаполненными датами
-- 2. Timezone: все даты в UTC, без учёта часовых поясов
-- 3. Тип дня: для расчёта доли периода используются РАБОЧИЕ дни (is_workday = TRUE)
-- 4. MTD (Month-To-Date): считается от начала месяца до текущей даты включительно
-- 5. Гранулярность плана: месяц × регион × категория
-- 6. Гранулярность факта: день × магазин × товар (агрегируется до месяц × регион × категория)

-- СТРАТЕГИЯ ИНКРЕМЕНТАЛЬНОЙ ЗАГРУЗКИ:
-- fact_sales_daily: MERGE по ключу (sale_date, store_id, sku_id)
--   - Обновление данных за последние 3 дня (возможны корректировки возвратов)
--   - Append для новых дат
-- fact_plan_monthly: MERGE по ключу (plan_month, region, category)
--   - Полная перезагрузка плана при изменениях
-- dim_*: SCD Type 1 для большинства атрибутов, кроме критичных изменений

-- ============================================================
-- CTE 1: Агрегация продаж день -> месяц с измерениями
-- ============================================================
WITH sales_daily_enriched AS (
    SELECT 
        f.sale_date,
        c.year_num,
        c.month_num,
        DATE_TRUNC('month', f.sale_date)::DATE AS sale_month,
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
    FROM mart.fact_sales_daily f
    INNER JOIN mart.dim_calendar c ON f.sale_date = c.calendar_date
    INNER JOIN mart.dim_store s ON f.store_id = s.store_id
    INNER JOIN mart.dim_sku sk ON f.sku_id = sk.sku_id
    WHERE s.is_active = TRUE  -- только активные магазины
),

-- ============================================================
-- CTE 2: Агрегация продаж до гранулярности плана (месяц × регион × категория)
-- ============================================================
sales_monthly_agg AS (
    SELECT 
        sale_month,
        year_num,
        month_num,
        region,
        category,
        SUM(net_revenue) AS actual_revenue_mtd,
        SUM(gross_revenue) AS gross_revenue_mtd,
        SUM(returns_amt) AS returns_amt_mtd,
        SUM(receipt_count) AS receipt_count_mtd,
        COUNT(DISTINCT store_id) AS stores_count,
        COUNT(DISTINCT sku_id) AS sku_count,
        COUNT(DISTINCT sale_date) AS days_with_sales
    FROM sales_daily_enriched
    GROUP BY sale_month, year_num, month_num, region, category
),

-- ============================================================
-- CTE 3: Расчёт доли периода (на основе рабочих дней)
-- ============================================================
period_progress AS (
    SELECT 
        DATE_TRUNC('month', calendar_date)::DATE AS period_month,
        COUNT(*) FILTER (WHERE is_workday = TRUE) AS total_workdays_in_month,
        COUNT(*) AS total_calendar_days_in_month,
        -- Считаем прошедшие рабочие дни до максимальной даты с продажами
        COUNT(*) FILTER (
            WHERE is_workday = TRUE 
            AND calendar_date <= (SELECT MAX(sale_date) FROM mart.fact_sales_daily)
        ) AS elapsed_workdays_mtd,
        COUNT(*) FILTER (
            WHERE calendar_date <= (SELECT MAX(sale_date) FROM mart.fact_sales_daily)
        ) AS elapsed_calendar_days_mtd,
        MAX(calendar_date) FILTER (
            WHERE calendar_date <= (SELECT MAX(sale_date) FROM mart.fact_sales_daily)
        ) AS last_sale_date
    FROM mart.dim_calendar
    WHERE calendar_date >= DATE_TRUNC('month', (SELECT MIN(sale_date) FROM mart.fact_sales_daily))
      AND calendar_date <= DATE_TRUNC('month', (SELECT MAX(sale_date) FROM mart.fact_sales_daily)) + INTERVAL '1 month' - INTERVAL '1 day'
    GROUP BY DATE_TRUNC('month', calendar_date)::DATE
),

-- ============================================================
-- CTE 4: Присоединение плана к факту
-- ============================================================
plan_vs_actual AS (
    SELECT 
        COALESCE(s.sale_month, p.plan_month) AS report_month,
        COALESCE(s.year_num, EXTRACT(YEAR FROM p.plan_month)::SMALLINT) AS year_num,
        COALESCE(s.month_num, EXTRACT(MONTH FROM p.plan_month)::SMALLINT) AS month_num,
        COALESCE(s.region, p.region) AS region,
        COALESCE(s.category, p.category) AS category,
        
        -- Факт
        COALESCE(s.actual_revenue_mtd, 0) AS actual_revenue_mtd,
        COALESCE(s.gross_revenue_mtd, 0) AS gross_revenue_mtd,
        COALESCE(s.returns_amt_mtd, 0) AS returns_amt_mtd,
        COALESCE(s.receipt_count_mtd, 0) AS receipt_count_mtd,
        COALESCE(s.stores_count, 0) AS stores_count,
        COALESCE(s.sku_count, 0) AS sku_count,
        COALESCE(s.days_with_sales, 0) AS days_with_sales,
        
        -- План
        COALESCE(p.target_revenue, 0) AS target_revenue_month,
        COALESCE(p.target_qty, 0) AS target_qty_month,
        
        -- Прогресс периода
        pp.total_workdays_in_month,
        pp.elapsed_workdays_mtd,
        pp.total_calendar_days_in_month,
        pp.elapsed_calendar_days_mtd,
        pp.last_sale_date
        
    FROM sales_monthly_agg s
    FULL OUTER JOIN mart.fact_plan_monthly p 
        ON s.sale_month = p.plan_month 
        AND s.region = p.region 
        AND s.category = p.category
    LEFT JOIN period_progress pp 
        ON COALESCE(s.sale_month, p.plan_month) = pp.period_month
),

-- ============================================================
-- CTE 5: Расчёт метрик план-факт
-- ============================================================
kpi_metrics AS (
    SELECT 
        report_month,
        year_num,
        month_num,
        region,
        category,
        
        -- Факт MTD
        actual_revenue_mtd,
        gross_revenue_mtd,
        returns_amt_mtd,
        receipt_count_mtd,
        stores_count,
        sku_count,
        days_with_sales,
        
        -- План
        target_revenue_month,
        target_qty_month,
        
        -- Доля периода (на основе рабочих дней)
        ROUND(
            CASE 
                WHEN total_workdays_in_month > 0 
                THEN 100.0 * elapsed_workdays_mtd / total_workdays_in_month
                ELSE 0 
            END, 
            2
        ) AS period_progress_pct,
        
        elapsed_workdays_mtd,
        total_workdays_in_month,
        elapsed_calendar_days_mtd,
        total_calendar_days_in_month,
        last_sale_date,
        
        -- Ожидаемый план MTD (пропорционально доле периода)
        ROUND(
            CASE 
                WHEN total_workdays_in_month > 0 
                THEN target_revenue_month * elapsed_workdays_mtd / total_workdays_in_month
                ELSE 0 
            END, 
            2
        ) AS expected_revenue_mtd,
        
        -- Отклонение факта от ожидаемого плана MTD
        ROUND(
            actual_revenue_mtd - 
            CASE 
                WHEN total_workdays_in_month > 0 
                THEN target_revenue_month * elapsed_workdays_mtd / total_workdays_in_month
                ELSE 0 
            END, 
            2
        ) AS deviation_from_expected,
        
        -- Отклонение факта от полного плана месяца
        ROUND(actual_revenue_mtd - target_revenue_month, 2) AS deviation_from_target,
        
        -- % выполнения плана (факт MTD / полный план месяца)
        ROUND(
            CASE 
                WHEN target_revenue_month > 0 
                THEN 100.0 * actual_revenue_mtd / target_revenue_month
                ELSE 0 
            END, 
            2
        ) AS achievement_pct,
        
        -- % выполнения ожидаемого плана MTD
        ROUND(
            CASE 
                WHEN total_workdays_in_month > 0 AND target_revenue_month > 0
                THEN 100.0 * actual_revenue_mtd / (target_revenue_month * elapsed_workdays_mtd / total_workdays_in_month)
                ELSE 0 
            END, 
            2
        ) AS mtd_achievement_pct,
        
        -- Средний чек
        ROUND(
            CASE 
                WHEN receipt_count_mtd > 0 
                THEN actual_revenue_mtd / receipt_count_mtd
                ELSE 0 
            END, 
            2
        ) AS avg_receipt_value,
        
        -- % возвратов
        ROUND(
            CASE 
                WHEN gross_revenue_mtd > 0 
                THEN 100.0 * returns_amt_mtd / gross_revenue_mtd
                ELSE 0 
            END, 
            2
        ) AS returns_pct
        
    FROM plan_vs_actual
),

-- ============================================================
-- CTE 6: АНАЛИТИКА ДЛЯ КАТЕГОРИЙНОГО МЕНЕДЖЕРА
-- Детализация по категориям с дополнительными метриками
-- ============================================================
category_analytics AS (
    SELECT 
        sde.sale_month,
        sde.region,
        sde.category,
        sde.sku_code,
        sde.sku_name,
        
        -- Продажи по SKU
        SUM(sde.net_revenue) AS sku_revenue_mtd,
        SUM(sde.receipt_count) AS sku_receipt_count,
        SUM(sde.returns_amt) AS sku_returns_amt,
        
        -- Доля SKU в категории
        ROUND(
            100.0 * SUM(sde.net_revenue) / 
            SUM(SUM(sde.net_revenue)) OVER (PARTITION BY sde.sale_month, sde.region, sde.category),
            2
        ) AS sku_share_in_category_pct,
        
        -- Количество магазинов, где продавался SKU
        COUNT(DISTINCT sde.store_id) AS stores_with_sku,
        
        -- Количество дней с продажами SKU
        COUNT(DISTINCT sde.sale_date) AS days_with_sku_sales,
        
        -- Средняя дневная выручка по SKU
        ROUND(SUM(sde.net_revenue) / COUNT(DISTINCT sde.sale_date), 2) AS avg_daily_revenue,
        
        -- Ранг SKU в категории по выручке
        RANK() OVER (
            PARTITION BY sde.sale_month, sde.region, sde.category 
            ORDER BY SUM(sde.net_revenue) DESC
        ) AS sku_rank_in_category
        
    FROM sales_daily_enriched sde
    GROUP BY 
        sde.sale_month,
        sde.region,
        sde.category,
        sde.sku_code,
        sde.sku_name
),

-- ============================================================
-- CTE 7: Топ и аутсайдеры по категориям
-- ============================================================
category_top_bottom AS (
    SELECT 
        sale_month,
        region,
        category,
        
        -- Топ-3 SKU по выручке
        STRING_AGG(
            CASE WHEN sku_rank_in_category <= 3 
            THEN sku_name || ' (' || sku_revenue_mtd || ' руб.)'
            ELSE NULL END,
            ', '
        ) AS top_3_skus,
        
        -- Худшие SKU (с минимальной выручкой)
        STRING_AGG(
            CASE WHEN sku_rank_in_category > (
                SELECT COUNT(*) FROM category_analytics ca2 
                WHERE ca2.sale_month = category_analytics.sale_month 
                AND ca2.region = category_analytics.region 
                AND ca2.category = category_analytics.category
            ) - 2
            THEN sku_name || ' (' || sku_revenue_mtd || ' руб.)'
            ELSE NULL END,
            ', '
        ) AS bottom_3_skus,
        
        -- Средняя выручка по SKU в категории
        ROUND(AVG(sku_revenue_mtd), 2) AS avg_sku_revenue,
        
        -- Количество SKU в категории
        COUNT(DISTINCT sku_code) AS total_skus_in_category
        
    FROM category_analytics
    GROUP BY sale_month, region, category
),

-- ============================================================
-- CTE 8: Динамика категорий (сравнение с предыдущим месяцем)
-- ============================================================
category_dynamics AS (
    SELECT 
        report_month,
        region,
        category,
        actual_revenue_mtd,
        
        -- Выручка предыдущего месяца
        LAG(actual_revenue_mtd) OVER (
            PARTITION BY region, category 
            ORDER BY report_month
        ) AS prev_month_revenue,
        
        -- Рост/падение выручки
        ROUND(
            actual_revenue_mtd - LAG(actual_revenue_mtd) OVER (
                PARTITION BY region, category 
                ORDER BY report_month
            ),
            2
        ) AS revenue_change,
        
        -- % изменения выручки
        ROUND(
            CASE 
                WHEN LAG(actual_revenue_mtd) OVER (
                    PARTITION BY region, category 
                    ORDER BY report_month
                ) > 0
                THEN 100.0 * (
                    actual_revenue_mtd - LAG(actual_revenue_mtd) OVER (
                        PARTITION BY region, category 
                        ORDER BY report_month
                    )
                ) / LAG(actual_revenue_mtd) OVER (
                    PARTITION BY region, category 
                    ORDER BY report_month
                )
                ELSE 0
            END,
            2
        ) AS revenue_change_pct
        
    FROM kpi_metrics
)

-- ============================================================
-- ФИНАЛЬНЫЙ РЕЗУЛЬТАТ: Витрина для дашборда
-- ============================================================
SELECT 
    -- Измерения
    km.report_month::DATE AS report_month,
    km.year_num::SMALLINT AS year_num,
    km.month_num::SMALLINT AS month_num,
    km.region::VARCHAR(60) AS region,
    km.category::VARCHAR(60) AS category,
    
    -- Факт MTD
    km.actual_revenue_mtd::NUMERIC(14,2) AS actual_revenue_mtd,
    km.gross_revenue_mtd::NUMERIC(14,2) AS gross_revenue_mtd,
    km.returns_amt_mtd::NUMERIC(12,2) AS returns_amt_mtd,
    km.receipt_count_mtd::INTEGER AS receipt_count_mtd,
    km.stores_count::INTEGER AS stores_count,
    km.sku_count::INTEGER AS sku_count,
    km.days_with_sales::INTEGER AS days_with_sales,
    
    -- План
    km.target_revenue_month::NUMERIC(14,2) AS target_revenue_month,
    km.target_qty_month::INTEGER AS target_qty_month,
    
    -- Прогресс периода
    km.period_progress_pct::NUMERIC(5,2) AS period_progress_pct,
    km.elapsed_workdays_mtd::INTEGER AS elapsed_workdays_mtd,
    km.total_workdays_in_month::INTEGER AS total_workdays_in_month,
    km.elapsed_calendar_days_mtd::INTEGER AS elapsed_calendar_days_mtd,
    km.total_calendar_days_in_month::INTEGER AS total_calendar_days_in_month,
    km.last_sale_date::DATE AS last_sale_date,
    
    -- План-факт метрики
    km.expected_revenue_mtd::NUMERIC(14,2) AS expected_revenue_mtd,
    km.deviation_from_expected::NUMERIC(14,2) AS deviation_from_expected,
    km.deviation_from_target::NUMERIC(14,2) AS deviation_from_target,
    km.achievement_pct::NUMERIC(6,2) AS achievement_pct,
    km.mtd_achievement_pct::NUMERIC(6,2) AS mtd_achievement_pct,
    
    -- Дополнительные метрики
    km.avg_receipt_value::NUMERIC(10,2) AS avg_receipt_value,
    km.returns_pct::NUMERIC(5,2) AS returns_pct,
    
    -- Аналитика для категорийного менеджера
    ctb.top_3_skus::TEXT AS top_3_skus,
    ctb.bottom_3_skus::TEXT AS bottom_3_skus,
    ctb.avg_sku_revenue::NUMERIC(12,2) AS avg_sku_revenue,
    ctb.total_skus_in_category::INTEGER AS total_skus_in_category,
    
    -- Динамика
    cd.prev_month_revenue::NUMERIC(14,2) AS prev_month_revenue,
    cd.revenue_change::NUMERIC(14,2) AS revenue_change,
    cd.revenue_change_pct::NUMERIC(6,2) AS revenue_change_pct,
    
    -- Статус выполнения плана (для визуализации)
    CASE 
        WHEN km.mtd_achievement_pct >= 100 THEN 'Выполнен'
        WHEN km.mtd_achievement_pct >= 90 THEN 'В пределах нормы'
        WHEN km.mtd_achievement_pct >= 70 THEN 'Требует внимания'
        ELSE 'Критично'
    END::VARCHAR(20) AS plan_status,
    
    -- Тренд (для визуализации)
    CASE 
        WHEN cd.revenue_change_pct > 10 THEN 'Сильный рост'
        WHEN cd.revenue_change_pct > 0 THEN 'Рост'
        WHEN cd.revenue_change_pct = 0 THEN 'Стабильно'
        WHEN cd.revenue_change_pct > -10 THEN 'Снижение'
        ELSE 'Сильное снижение'
    END::VARCHAR(20) AS trend
    
FROM kpi_metrics km
LEFT JOIN category_top_bottom ctb 
    ON km.report_month = ctb.sale_month 
    AND km.region = ctb.region 
    AND km.category = ctb.category
LEFT JOIN category_dynamics cd 
    ON km.report_month = cd.report_month 
    AND km.region = cd.region 
    AND km.category = cd.category

ORDER BY 
    km.report_month DESC,
    km.region,
    km.category;

-- ============================================================
-- ПРИМЕЧАНИЯ ДЛЯ BI-СЛОЯ:
-- 
-- 1. Все колонки имеют явные типы данных для Direct Query в Power BI/Fine BI
-- 2. Метрики готовы к использованию без дополнительных вычислений
-- 3. Поля plan_status и trend можно использовать для условного форматирования
-- 4. Для визуализации трендов используйте поля revenue_change и revenue_change_pct
-- 5. Для drill-down анализа по SKU используйте CTE category_analytics отдельно
-- 
-- РЕКОМЕНДАЦИИ ПО ИСПОЛЬЗОВАНИЮ:
-- 
-- - Для дашборда топ-менеджмента: используйте агрегацию по region
-- - Для категорийного менеджера: фильтруйте по category и анализируйте top_3_skus
-- - Для регионального менеджера: фильтруйте по region и анализируйте все категории
-- - Для прогнозирования: используйте mtd_achievement_pct и period_progress_pct
-- 
-- ============================================================
