# Лабораторная работа 4 - отчёт

## 1. Индексы (сравнение до/после)

| Запрос                                                                      | План до индекса (пример)                                                               | План после индекса (пример)                                                                    | Комментарий                                                                                                                                                                      |
| --------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Фильтр по `users.country='USA'` с сортировкой по `city` | `Seq Scan on users (rows=6, cost=0.00..1.30, actual 0.018 ms)` + `Sort (actual 0.026 ms)`             | После `CREATE INDEX idx_lab4_users_country_city` план остался `Seq Scan (actual 0.019 ms)`       | На тестовых данных (6 строк) индекс логически подходит, но оптимизатор предпочитает читать всю таблицу |
| Диапазон по `sessions.actual_started_at`                              | `Seq Scan on sessions (rows=3, cost=0.00..1.05, actual 0.041 ms)`                                       | `CREATE INDEX idx_lab4_sessions_started_at` → план без изменений (`Seq Scan`, actual 0.026 ms) | Объём сильно мал; при реальных данных индекс позволит `Index Scan` и избавит от сортировки                               |
| Поиск подстроки в `messages.body`                                | `Seq Scan on messages (rows=4, actual 0.034 ms)` с фильтром `ILIKE '%архитектур%'` | GIN `idx_lab4_messages_body_trgm` создан, но план остаётся `Seq Scan (actual 0.021 ms)`      | GIN готов для прод‑объёмов; сейчас дешевле просканировать все сообщения                                                          |

## 2. Агрегатный запрос после индексов

```
EXPLAIN (ANALYZE, VERBOSE)
SELECT mentor.username,
       COUNT(*) FILTER (WHERE b.status = 'completed') AS completed_cnt,
       SUM(b.price_total) AS revenue
FROM mentor_offers o
JOIN users mentor ON mentor.user_id = o.mentor_id
LEFT JOIN bookings b ON b.offer_id = o.offer_id
WHERE mentor.country = 'Germany'
GROUP BY mentor.username;
```

Пример плана: `Hash Join` (cost≈1.20..2.50, actual 0.045 ms), `Seq Scan` по `mentor_offers` и `bookings`. Даже после индексов оптимизатор выбирает полный проход из‑за маленького объёма. В отчёте отмечаем, что при росте данных появится `Index Scan` по `idx_lab4_users_country_city`.

## 3. Транзакционные сценарии (T1/T2)

| Сценарий    | T1                                                          | T2                                                                | Наблюдение                                                           | Устранение                                                                                                             |
| ------------------- | ----------------------------------------------------------- | ----------------------------------------------------------------- | ------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------- |
| Non-repeatable read | `READ COMMITTED` (чтение баланса 150 → 175) | `READ COMMITTED` (`+25` через dblink)                    | Второй SELECT в T1 видит 175                                       | Повтор с `REPEATABLE READ` фиксирует 150 на весь сеанс                                              |
| Phantom read        | `READ COMMITTED` (`COUNT`=1 → 2)                       | `READ COMMITTED` (вставляет цель 15 апреля) | Число строк увеличилось внутри транзакции | `SERIALIZABLE` для T1 сохраняет `COUNT`=1, T2 ждёт                                                           |
| Lost update         | `READ COMMITTED` (T1: 200→230)                           | `READ COMMITTED` (T2: читает 200, пишет 170)         | Итог =170, правка T1 потеряна                                | В `SERIALIZABLE` T2 завершает `UPDATE` ошибкой `could not serialize…`, баланс остаётся 230 |

### Фрагмент журнала

```text
SELECT dblink_exec('lab4_conn', $$ UPDATE lab4_wallets … $$) AS t2_result;
-- ERROR: could not serialize access due to concurrent update
SELECT 'Balance after serializable protection' AS info, balance FROM lab4_wallets …;
```

Это демонстрирует ожидаемое поведение: после повышения уровня изоляции попытка T2 откатывается, баланс фиксируется T1.
