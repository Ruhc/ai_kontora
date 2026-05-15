# S2T Mapping — mart.daily_order_kpis
**Проект:** МегаБайт DWH/BI | **Путь:** Б (синтетические данные)  
**Аналитик:** AI-ассистент (Claude) + ручные правки  
**Дата:** 2026-05-15

## Витрина: mart.daily_order_kpis
**Зерно:** один ряд = один день × один магазин  
**Источники:** МегаБайт POS (PostgreSQL реплика), 1С-Предприятие, Excel (коммерческий директор), dim_calendar (DWH-справочник)  
**Обновление:** ежедневно к 08:00 МСК, результаты D-1

---

| target_table | target_column | data_type | source_system | source_table | source_column | transformation_rule | business_rule | is_nullable | default_value | incremental_strategy |
|---|---|---|---|---|---|---|---|---|---|---|
| mart.daily_order_kpis | sale_date | DATE | МегаБайт POS | mart.fact_sales_daily | sale_date | `fact_sales_daily.sale_date` | Дата продажи (UTC); дашборд отображает МСК (UTC+3). Ключ 1 из 2. | NO | — | MERGE по (sale_date, store_id); окно пересчёта — последние 3 дня |
| mart.daily_order_kpis | store_id | VARCHAR(8) | МегаБайт POS | mart.fact_sales_daily | store_id | `fact_sales_daily.store_id` | Код магазина формата M-NNN. Ключ 2 из 2. | NO | — | — |
| mart.daily_order_kpis | store_name | VARCHAR(120) | 1С-Предприятие | mart.dim_store | store_name | `dim_store.store_name` (INNER JOIN по store_id) | Полное название магазина из справочника 1С. | NO | — | SCD-1 (перезапись при изменении) |
| mart.daily_order_kpis | region | VARCHAR(60) | 1С-Предприятие | mart.dim_store | region | `dim_store.region` (INNER JOIN по store_id) | Регион — ключ связи с plan-данными fact_plan_monthly. | NO | — | SCD-1 |
| mart.daily_order_kpis | city | VARCHAR(60) | 1С-Предприятие | mart.dim_store | city | `dim_store.city` (INNER JOIN по store_id) | Город для фильтрации в Fine BI / Power BI. | NO | — | SCD-1 |
| mart.daily_order_kpis | is_workday | BOOLEAN | МегаБайт DWH | mart.dim_calendar | is_workday | `dim_calendar.is_workday` (INNER JOIN по sale_date = calendar_date) | TRUE для пн-пт. Используется в расчёте period_progress_pct. В продакшене — производственный календарь РФ. | NO | — | Статическая таблица, 1 раз/год |
| mart.daily_order_kpis | gross_revenue | NUMERIC(12,2) | МегаБайт POS | mart.fact_sales_daily | gross_revenue | `SUM(gross_revenue) GROUP BY sale_date, store_id` | Валовая выручка по всем SKU за день до вычета скидок и возвратов. | NO | 0.00 | — |
| mart.daily_order_kpis | net_revenue | NUMERIC(12,2) | МегаБайт POS | mart.fact_sales_daily | net_revenue | `SUM(net_revenue) GROUP BY sale_date, store_id` | Чистая выручка (база для план-факт). Сумма по всем SKU за день. | NO | 0.00 | — |
| mart.daily_order_kpis | returns_amt | NUMERIC(12,2) | МегаБайт POS | mart.fact_sales_daily | returns_amt | `SUM(returns_amt) GROUP BY sale_date, store_id` | Сумма возвратов за день. Корректировки от M-104/M-217/M-089 приходят с задержкой до 2 суток — поэтому окно MERGE 3 дня. | NO | 0.00 | — |
| mart.daily_order_kpis | receipt_count | INTEGER | МегаБайт POS | mart.fact_sales_daily | receipt_count | `SUM(receipt_count) GROUP BY sale_date, store_id` | Количество чеков за день по магазину. | NO | 0 | — |
| mart.daily_order_kpis | sku_count | INTEGER | МегаБайт POS | mart.fact_sales_daily | sku_id | `COUNT(DISTINCT sku_id) GROUP BY sale_date, store_id` | Количество уникальных SKU, проданных за день. | NO | 0 | — |
| mart.daily_order_kpis | avg_receipt_value | NUMERIC(10,2) | вычисляемое | mart.fact_sales_daily | net_revenue, receipt_count | `ROUND(CASE WHEN SUM(receipt_count) > 0 THEN SUM(net_revenue) / SUM(receipt_count) ELSE NULL END, 2)` | Средний чек. NULL если чеков нет (выходной или закрытый магазин) — не 0, чтобы не искажать средние в дашборде. | YES | NULL | — |
| mart.daily_order_kpis | returns_pct | NUMERIC(5,2) | вычисляемое | mart.fact_sales_daily | returns_amt, gross_revenue | `ROUND(CASE WHEN SUM(gross_revenue) > 0 THEN 100.0 * SUM(returns_amt) / SUM(gross_revenue) ELSE NULL END, 2)` | % возвратов от валовой выручки. NULL при нулевой выручке. Порог тревоги: >5% для операционного мониторинга Ирины Соколовой. | YES | NULL | — |
| mart.daily_order_kpis | plan_revenue_month | NUMERIC(14,2) | Excel (ком. директор) | mart.fact_plan_monthly | target_revenue | `fact_plan_monthly.target_revenue` (LEFT JOIN по DATE_TRUNC('month',sale_date)=plan_month AND dim_store.region=region AND dim_sku.category=category; агрегация по region) | Плановая выручка на месяц для региона магазина. NULL при FULL OUTER JOIN, если для месяца/региона план не поступил. Нестабильный формат Excel. | YES | NULL | FULL REFRESH при поступлении нового Excel-файла |
| mart.daily_order_kpis | period_progress_pct | NUMERIC(5,2) | МегаБайт DWH | mart.dim_calendar | is_workday, calendar_date | `ROUND(100.0 * COUNT(*) FILTER (WHERE is_workday AND calendar_date <= sale_date AND DATE_TRUNC('month',calendar_date)=DATE_TRUNC('month',sale_date)) / NULLIF(COUNT(*) FILTER (WHERE is_workday AND DATE_TRUNC('month',calendar_date)=DATE_TRUNC('month',sale_date)), 0), 2)` | Доля рабочих дней прошедшая в месяце на дату sale_date. Рабочие дни — не календарные, т.к. планы МегаБайт формируются на кол-во рабочих дней пн-пт. | YES | NULL | — |
| mart.daily_order_kpis | plan_status | VARCHAR(20) | вычисляемое | — | — | `CASE WHEN plan_revenue_month IS NULL THEN 'Нет плана' WHEN period_progress_pct IS NULL THEN 'Нет данных' WHEN net_revenue >= plan_revenue_month * period_progress_pct / 100.0 THEN 'Выполнен' WHEN net_revenue >= plan_revenue_month * period_progress_pct / 100.0 * 0.9 THEN 'В норме' WHEN net_revenue >= plan_revenue_month * period_progress_pct / 100.0 * 0.7 THEN 'Внимание' ELSE 'Критично' END` | Светофор KPI для операционного дашборда (зелёный ≥100%, жёлтый 90-100%, оранжевый 70-90%, красный <70%). Цветовая шкала согласована с Мариной Черновой (BI). | YES | 'Нет данных' | — |
| mart.daily_order_kpis | load_ts | TIMESTAMPTZ | ETL-оркестратор (Airflow) | — | — | `CURRENT_TIMESTAMP` | Время загрузки пакета (UTC). Служебное поле для аудита пайплайна и диагностики задержек. | NO | CURRENT_TIMESTAMP | — |
| mart.daily_order_kpis | is_deleted | BOOLEAN | ETL-оркестратор (Airflow) | — | — | `FALSE` | Флаг логического удаления строки. TRUE при ретроспективной отмене дня (сторно). | NO | FALSE | — |

---

## Источники данных

| Источник | Система | Схема/таблица в DWH | Частота обновления | Особенности |
|---|---|---|---|---|
| Транзакции продаж | МегаБайт POS (PostgreSQL реплика) | mart.fact_sales_daily | Ежедневно, ~45 тыс. чеков/день | M-104/M-217/M-089 — другой POS-формат, нормализация до загрузки |
| Справочник магазинов | 1С-Предприятие | mart.dim_store | По событию (открытие/закрытие) | SCD-1; is_active = FALSE для закрытых магазинов |
| Справочник SKU | 1С-Предприятие | mart.dim_sku | По событию (~15 тыс. активных SKU) | SCD-1 |
| Месячные планы | Excel (коммерческий директор) | mart.fact_plan_monthly | По событию (1 раз/месяц, нестабильный формат) | FULL REFRESH при каждом поступлении файла |
| Производственный календарь | МегаБайт DWH (генерируется) | mart.dim_calendar | 1 раз в год (на следующий год) | В MVP: пн-пт без праздников; в продакшене — официальный производственный календарь РФ |

---

## Стратегия инкрементальной загрузки mart.daily_order_kpis

```
Источник:    mart.fact_sales_daily
Стратегия:   MERGE по ключу (sale_date, store_id)
Окно:        последние 3 дня от MAX(sale_date) в пайплайне
Причина:     магазины M-104, M-217, M-089 присылают корректировки возвратов
             с задержкой до 2 рабочих суток → окно 3 дня покрывает все поздние сторно

Источник:    mart.fact_plan_monthly
Стратегия:   FULL REFRESH при поступлении нового Excel-файла
Причина:     нестабильный формат, коммерческий директор может обновить весь месяц

Источник:    mart.dim_store / mart.dim_sku
Стратегия:   SCD Type 1 (перезапись атрибутов)
Причина:     исторические значения не требуются; is_active обновляется немедленно

Результирующая витрина mart.daily_order_kpis:
  Гранулярность:  день × магазин
  Загрузка:       MERGE по (sale_date, store_id) с тем же 3-дневным окном
  Горизонт:       rolling 13 месяцев; более старые месяцы → архивная партиция
```
