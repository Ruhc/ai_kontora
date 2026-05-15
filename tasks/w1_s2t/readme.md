# S2T Mapping — mart.daily_order_kpis

**Задача:** w1_s2t | **Путь:** Б (синтетические данные МегаБайт) | **Дата:** 2026-05-15

---

## 1. Рутина

Без ИИ: аналитик открывает DDL источников, вручную переносит колонки в Excel-шаблон, пишет transformation_rule по памяти или из документации — 2-4 часа на 18+ строк с бизнес-правилами и incremental_strategy.

---

## 2. Промпт / шаги для ИИ

**Промпт (ключевой):**

```
Ты — системный аналитик на проекте DWH для розничной сети МегаБайт (~120 магазинов,
PostgreSQL + Fine BI). Нужно составить S2T-маппинг для витрины mart.daily_order_kpis
(зерно: день × магазин).

Источники из DDL:
  mart.fact_sales_daily   — (sale_date, store_id, sku_id, gross_revenue, net_revenue, returns_amt, receipt_count)
  mart.fact_plan_monthly  — (plan_month, region, category, target_revenue, target_qty)
  mart.dim_store          — (store_id, store_name, region, city, open_date, is_active)
  mart.dim_sku            — (sku_id, sku_code, sku_name, category, unit_price)
  mart.dim_calendar       — (calendar_date, is_workday, month_num, year_num, ...)

Заполни таблицу с колонками:
  target_table | target_column | data_type | source_system | source_table | source_column
  | transformation_rule (SQL-выражение) | business_rule | is_nullable | default_value
  | incremental_strategy

Требования:
  - ≥12 строк, включая служебные (load_ts, is_deleted)
  - ≥3 нетривиальных transformation_rule (CASE, SUM/COUNT DISTINCT, lookup)
  - incremental_strategy заполнена для ≥2 полей
  - plan-колонки: is_nullable=YES (FULL OUTER JOIN с fact_plan_monthly может дать NULL)
  - fact_sales_daily: MERGE окно 3 дня (M-104/M-217/M-089 шлют возвраты с задержкой 2 дня)
  - period_progress_pct: через рабочие дни (is_workday), не календарные
```

**Шаги:**
1. Подать DDL трёх источников + шаблон таблицы → черновик 18 строк
2. Проверить вручную: source_system/source_table, is_nullable, incremental_strategy
3. Доработать: добавить load_ts/is_deleted, уточнить CASE для plan_status и avg_receipt_value

---

## 3. Ручные правки

**Правка 1. Окно MERGE для fact_sales_daily: стандартный APPEND → MERGE 3 дня**

*Было:* ИИ предложил стратегию `append` для поля sale_date — добавлять новые строки без пересчёта старых.

*Стало:* `MERGE по (sale_date, store_id), окно 3 дня`.

*Почему:* Магазины M-104, M-217, M-089 работают на отдельном POS-формате и присылают корректировки возвратов с задержкой до 2 рабочих суток. При APPEND эти корректировки появятся как дублирующие строки или вообще потеряются. Окно 3 дня гарантирует, что все сторно-чеки попадут в итоговую витрину.

---

**Правка 2. is_nullable для plan_revenue_month: NO → YES**

*Было:* ИИ поставил `is_nullable = NO` для поля plan_revenue_month, добавив COALESCE(target_revenue, 0).

*Стало:* `is_nullable = YES`, default_value = NULL.

*Почему:* Витрина строится через FULL OUTER JOIN факта продаж и плановой таблицы. При отсутствии плана на новый регион или категорию строка плана не существует, и COALESCE(0) маскирует этот факт — в дашборде появится «план = 0», что вводит операционных менеджеров в заблуждение. NULL корректно обрабатывается в Fine BI как «нет плана» и не влияет на расчёт plan_status (явный `CASE WHEN plan_revenue_month IS NULL THEN 'Нет плана'`).

---

**Правка 3. period_progress_pct: календарные дни → рабочие дни**

*Было:* ИИ предложил `ROUND(100.0 * EXTRACT(DAY FROM sale_date) / EXTRACT(DAY FROM DATE_TRUNC('month', sale_date) + INTERVAL '1 month - 1 day'), 2)` — доля прошедших календарных дней.

*Стало:* `COUNT(*) FILTER (WHERE is_workday AND calendar_date <= sale_date) / NULLIF(COUNT(*) FILTER (WHERE is_workday AND ...), 0) * 100` через `mart.dim_calendar`.

*Почему:* Месячные планы в МегаБайт формируются коммерческим директором на рабочие дни (пн-пт). Расчёт через календарные дни давал бы ложное «перевыполнение» плана в недели с праздниками и «недовыполнение» в недели с пятью рабочими днями. Например, март 2024 имеет 21 рабочий день из 31 — на 8 марта (пятница) калendarный прогресс ~25%, а рабочий — только ~19%.

---

**Правка 4. avg_receipt_value: деление без CASE → CASE + NULL при отсутствии чеков**

*Было:* ИИ написал `ROUND(SUM(net_revenue) / SUM(receipt_count), 2)` — деление без защиты от нуля.

*Стало:* `ROUND(CASE WHEN SUM(receipt_count) > 0 THEN SUM(net_revenue) / SUM(receipt_count) ELSE NULL END, 2)`.

*Почему:* В выходные дни и при закрытых магазинах receipt_count = 0. Деление на 0 в PostgreSQL даёт ошибку (для INTEGER) или NaN (для NUMERIC). Значение NULL семантически правильно: «среднего чека нет, т.к. продаж не было» — не 0, иначе min(avg_receipt) по сети будет 0 вместо реального минимума.

---

## 4. Результат

**Экономия времени:** черновик 18 строк с transformation_rule за ~3 минуты вместо 2-3 часов ручного заполнения. Ручные правки (окно MERGE, is_nullable, рабочие дни, NULL-защита) заняли ~25 минут.

**Качество:** ИИ корректно заполнил source_table/source_column из DDL и не выдумал несуществующих таблиц. Ошибки были в бизнес-логике (окно возвратов, тип дней для прогресса) — именно там, где без знания проекта угадать невозможно.

**Следующий шаг:** маппинг используется в w2_profile (неделя 2) для профилирования тех же источников: mart.fact_sales_daily и mart.fact_plan_monthly.

---

## 5. Файлы в архиве

| Файл | Описание |
|---|---|
| `s2t_mapping.md` | S2T-таблица маппинга, 18 строк, все обязательные колонки + incremental_strategy |
| `readme.md` | Паспорт делегирования: промпт, 4 ручные правки с обоснованием |
