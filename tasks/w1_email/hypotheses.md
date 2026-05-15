# Технические гипотезы — Расхождение витрины с POS (16.04.2024)

**Роль:** Аналитик (BI-консалтинг)  
**Статус:** Рабочий документ, НЕ для передачи заказчику  
**Затронутые магазины:** M-104, M-217, M-089 (нестандартный формат store_id, версия POS v1.x)  
**Период расхождения:** 14.04–16.04.2024 | **Уровень расхождения:** 4,7% по gross_revenue

---

## Гипотеза 1: Сбой нормализации store_id после обновления маппинга 14.04

**Описание:** M-104, M-217, M-089 передают `store_id` в числовом формате без префикса «M-» (например, `104` вместо `M-104`). ETL применяет маппинг-таблицу для нормализации. Если 14.04 маппинг был обновлён некорректно:
- **Сценарий A (задвоение):** в витрину попали строки и с ID `104`, и с `M-104` → суммарная выручка задвоена
- **Сценарий B (потеря строк):** строки с числовым ID были отброшены как «не найденные в dim_store» → выручка занижена

**Связь с протоколом:** известная проблема, зафиксированная на встрече 19.02.2024 (AI#1 из протокола w1_proto).

**SQL для проверки (Сценарий A — задвоение):**
```sql
-- Ищем оба варианта store_id в витрине за период расхождения
SELECT
    store_id,
    sale_date,
    COUNT(*)               AS row_count,
    COUNT(DISTINCT receipt_id) AS unique_receipts,
    SUM(gross_revenue)     AS total_gross
FROM mart.fact_sales_daily
WHERE sale_date BETWEEN '2024-04-14' AND '2024-04-16'
  AND (store_id IN ('M-104', 'M-217', 'M-089')
       OR store_id IN ('104', '217', '089'))
GROUP BY store_id, sale_date
ORDER BY sale_date, store_id;
-- Признак проблемы: строки с '104' наряду с 'M-104' — задвоение
-- Или: строк '104' нет, но нет и 'M-104' за нужную дату — потеря
```

**SQL для проверки (Сценарий B — coverage по магазинам):**
```sql
-- Проверяем, есть ли пропуски по магазинам в ожидаемые даты
SELECT
    dd.calendar_date,
    ds.store_id,
    COALESCE(SUM(f.gross_revenue), 0) AS gross,
    COUNT(f.receipt_id)               AS receipts
FROM mart.dim_calendar dd
CROSS JOIN mart.dim_store ds
LEFT JOIN mart.fact_sales_daily f
    ON f.sale_date = dd.calendar_date
   AND f.store_id  = ds.store_id
WHERE dd.calendar_date BETWEEN '2024-04-14' AND '2024-04-16'
  AND ds.store_id IN ('M-104', 'M-217', 'M-089')
  AND dd.is_workday = TRUE
GROUP BY dd.calendar_date, ds.store_id
ORDER BY dd.calendar_date, ds.store_id;
-- Признак проблемы: gross = 0 и receipts = 0 для активного магазина в рабочий день
```

---

## Гипотеза 2: Возвраты с задержкой не попали в MERGE-цикл

**Описание:** ETL загружает POS-данные с окном MERGE 3 дня. Транзакции возвратов M-104/M-217/M-089 могут поступать в PostgreSQL-реплику с задержкой >24ч. Если возвраты за 16.04 пришли после 02:00 МСК 17.04 — они не войдут в загрузку за 16.04, и `net_revenue` в витрине будет завышен (возвраты не вычтены).

**SQL для проверки:**
```sql
-- Сравниваем витрину с staging-таблицей POS по суммам возвратов
-- Шаг 1: Что есть в витрине
SELECT
    store_id,
    sale_date,
    SUM(gross_revenue) AS dw_gross,
    SUM(returns_amt)   AS dw_returns,
    SUM(net_revenue)   AS dw_net
FROM mart.fact_sales_daily
WHERE sale_date = '2024-04-16'
  AND store_id IN ('M-104', 'M-217', 'M-089')
GROUP BY store_id, sale_date;

-- Шаг 2: Что пришло в staging из POS (включая поздние транзакции)
SELECT
    store_id,
    DATE(transaction_dt AT TIME ZONE 'UTC' AT TIME ZONE 'Europe/Moscow') AS msk_date,
    SUM(CASE WHEN transaction_type = 'SALE'   THEN amount       ELSE 0 END) AS pos_gross,
    SUM(CASE WHEN transaction_type = 'RETURN' THEN ABS(amount)  ELSE 0 END) AS pos_returns,
    MAX(transaction_dt) AS latest_tx_arrived
FROM pos_staging.transactions
WHERE store_id IN ('104', '217', '089', 'M-104', 'M-217', 'M-089')
  AND DATE(transaction_dt AT TIME ZONE 'UTC' AT TIME ZONE 'Europe/Moscow') = '2024-04-16'
GROUP BY store_id, msk_date;
-- Признак проблемы: pos_returns > dw_returns → возвраты не вошли в MERGE
-- Признак задержки: latest_tx_arrived > '2024-04-17 02:00 UTC'
```

---

## Гипотеза 3: Смещение дня из-за разницы UTC/МСК

**Описание:** Если POS-система сохраняет транзакции в UTC без явного указания TZ, а ETL считает, что timestamp уже в МСК — транзакции вечера МСК (21:00–23:59) попадут в день +1 в UTC. Итого: витрина за 16.04 недосчитается вечерних транзакций, а витрина за 17.04 получит их лишний раз.

**SQL для проверки:**
```sql
-- Смотрим на транзакции в «пограничной зоне» UTC vs MSK
SELECT
    DATE(transaction_dt)                                                AS utc_date,
    DATE(transaction_dt AT TIME ZONE 'Europe/Moscow')                   AS msk_date,
    store_id,
    COUNT(*)                                                            AS tx_count,
    SUM(amount)                                                         AS revenue
FROM pos_staging.transactions
WHERE store_id IN ('104', '217', '089', 'M-104', 'M-217', 'M-089')
  AND transaction_dt BETWEEN '2024-04-15 20:00:00+00' AND '2024-04-17 04:00:00+00'
GROUP BY utc_date, msk_date, store_id
ORDER BY utc_date, store_id;
-- Признак проблемы: utc_date != msk_date у строк с ненулевой выручкой
-- → ETL агрегировал по UTC, а нужно по MSK
```

---

## Гипотеза 4: Повторный запуск ETL — задвоение строк

**Описание:** Если ETL запускался дважды за один день (ручная перезапуск после ложной тревоги, сбой оркестрации) и не имеет защиты через `ON CONFLICT DO UPDATE`, строки дублируются — сумма удвоится.

**SQL для проверки:**
```sql
-- Ищем задвоенные строки по ключу (sale_date, store_id, sku_id)
SELECT
    sale_date,
    store_id,
    sku_id,
    COUNT(*)               AS row_count,
    COUNT(DISTINCT receipt_id) AS unique_receipts
FROM mart.fact_sales_daily
WHERE sale_date BETWEEN '2024-04-14' AND '2024-04-16'
  AND store_id IN ('M-104', 'M-217', 'M-089')
GROUP BY sale_date, store_id, sku_id
HAVING COUNT(*) > COUNT(DISTINCT receipt_id)
   OR  COUNT(*) > 1
ORDER BY sale_date, store_id;
-- Признак проблемы: row_count > 1 при одном sku_id за один день
```

**Дополнительно — проверка журнала ETL-запусков:**
```sql
-- Смотрим, был ли повторный запуск за 14–16.04
SELECT
    run_date,
    store_id_filter,
    started_at,
    finished_at,
    status,
    rows_inserted,
    rows_updated
FROM etl.job_runs
WHERE run_date BETWEEN '2024-04-14' AND '2024-04-16'
  AND job_name = 'load_fact_sales_daily'
ORDER BY run_date, started_at;
-- Признак проблемы: два завершённых запуска за одну и ту же run_date
```

---

## Приоритет проверки

| Приоритет | Гипотеза | Основание |
|-----------|----------|-----------|
| 🔴 P1 | Гипотеза 1 (store_id маппинг) | Расхождение началось 14.04 = дата обновления маппинга; затронуты именно магазины с нестандартным ID |
| 🟡 P2 | Гипотеза 2 (задержанные возвраты) | 4,7% — типичный масштаб для несостыковки возвратов; требует данных POS |
| 🟡 P2 | Гипотеза 4 (двойной запуск ETL) | Быстро проверяется по логам, не требует данных заказчика |
| 🟢 P3 | Гипотеза 3 (TZ-смещение) | Долгосрочная проблема; если была, должна была проявиться раньше |
