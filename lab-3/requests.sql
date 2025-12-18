-- =====================================================================================
-- Лабораторная работа 3. Mentorship Platform — процедуры, функции, триггеры
-- Допущение: схема mentorship_platform уже создана и наполнена данными из ЛР1-2.
-- =====================================================================================

SET search_path TO mentorship_platform;

-- 0. Служебные таблицы для триггеров/аудита -------------------------------------------
CREATE TABLE IF NOT EXISTS booking_message_audit (
  audit_id      BIGSERIAL PRIMARY KEY,
  message_id    BIGINT      NOT NULL,
  booking_id    BIGINT      NOT NULL,
  author_id     BIGINT      NOT NULL,
  body_preview  VARCHAR(200),
  created_at    TIMESTAMP   NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS mentor_rating_cache (
  mentor_id       BIGINT PRIMARY KEY,
  feedback_count  INTEGER    NOT NULL DEFAULT 0,
  avg_rating      NUMERIC(4,2) NOT NULL DEFAULT 0,
  updated_at      TIMESTAMP  NOT NULL DEFAULT now()
);

-- 1. Функции и процедуры -------------------------------------------------------------

-- 1.1 Функция бизнес-логики: создаёт бронирование с проверками и обработкой ошибок.
DROP FUNCTION IF EXISTS fn_create_booking(bigint, text, timestamp, integer);
CREATE OR REPLACE FUNCTION fn_create_booking(
  p_offer_id       BIGINT,
  p_mentee_username TEXT,
  p_starts_at       TIMESTAMP,
  p_duration_min    INTEGER
) RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
  v_mentee_id BIGINT;
  v_offer mentor_offers%ROWTYPE;
  v_booking_id BIGINT;
BEGIN
  IF p_duration_min <= 0 THEN
    RAISE EXCEPTION 'Длительность должна быть больше нуля минут.' USING ERRCODE = '22023';
  END IF;

  SELECT user_id INTO v_mentee_id FROM users WHERE username = p_mentee_username;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Пользователь % не найден.', p_mentee_username USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_offer FROM mentor_offers WHERE offer_id = p_offer_id AND status = 'active';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Активный оффер % не найден.', p_offer_id USING ERRCODE = 'P0002';
  END IF;

  IF v_offer.mentor_id = v_mentee_id THEN
    RAISE EXCEPTION 'Нельзя бронировать собственный оффер.' USING ERRCODE = 'P0003';
  END IF;

  -- Проверяем пересечение по времени у менти
  IF EXISTS (
      SELECT 1 FROM bookings b
      WHERE b.mentee_id = v_mentee_id
        AND tsrange(b.starts_at, b.ends_at) && tsrange(p_starts_at, p_starts_at + (p_duration_min || ' minutes')::interval)
        AND b.status IN ('pending','approved','completed')
  ) THEN
    RAISE EXCEPTION 'У пользователя % уже есть бронирование в это время.', p_mentee_username
      USING ERRCODE = 'P0003';
  END IF;

  INSERT INTO bookings (offer_id, mentee_id, starts_at, ends_at, status, currency, price_total, created_at)
  VALUES (
    p_offer_id,
    v_mentee_id,
    p_starts_at,
    p_starts_at + (p_duration_min || ' minutes')::interval,
    'pending',
    v_offer.currency,
    ROUND((v_offer.hourly_rate / 60) * p_duration_min, 2),
    now()
  )
  RETURNING booking_id INTO v_booking_id;

  RETURN v_booking_id;
EXCEPTION
  WHEN unique_violation THEN
    RAISE EXCEPTION 'Конфликт уникальности при создании бронирования: %', SQLERRM USING ERRCODE = 'P0004';
  WHEN foreign_key_violation THEN
    RAISE EXCEPTION 'Не найдены связанные данные для бронирования: %', SQLERRM USING ERRCODE = 'P0005';
END;
$$;

-- 1.2 Функция вычислительной аналитики по ментору
DROP FUNCTION IF EXISTS fn_get_mentor_stats(text);
CREATE OR REPLACE FUNCTION fn_get_mentor_stats(p_mentor_username TEXT)
RETURNS TABLE (
  mentor_id       BIGINT,
  mentor_username TEXT,
  total_bookings  INTEGER,
  completed_sessions INTEGER,
  revenue_total   NUMERIC,
  avg_rating      NUMERIC(4,2)
)
LANGUAGE plpgsql AS $$
BEGIN
  RETURN QUERY
  SELECT m.user_id,
         m.username::text,
         COUNT(DISTINCT b.booking_id)::int AS total_bookings,
         COUNT(DISTINCT s.session_id) FILTER (WHERE s.status = 'completed')::int AS completed_sessions,
         COALESCE(SUM(b.price_total) FILTER (WHERE b.status IN ('approved','completed')), 0) AS revenue_total,
         ROUND(AVG(f.rating)::numeric, 2) AS avg_rating
  FROM users m
  LEFT JOIN mentor_offers o ON o.mentor_id = m.user_id
  LEFT JOIN bookings b ON b.offer_id = o.offer_id
  LEFT JOIN sessions s ON s.booking_id = b.booking_id
  LEFT JOIN session_feedbacks f ON f.session_id = s.session_id AND f.target_id = m.user_id
  WHERE m.username = p_mentor_username
  GROUP BY m.user_id, m.username;
END;
$$;

-- 1.3 Процедура для смены статуса оффера с логированием и проверкой допустимых значений
DROP PROCEDURE IF EXISTS sp_update_offer_status(bigint, text);
CREATE OR REPLACE PROCEDURE sp_update_offer_status(p_offer_id BIGINT, p_new_status TEXT)
LANGUAGE plpgsql
AS $$
DECLARE
  v_allowed CONSTANT TEXT[] := ARRAY['active','paused','archived'];
BEGIN
  IF p_new_status IS NULL OR NOT (p_new_status = ANY (v_allowed)) THEN
    RAISE EXCEPTION 'Недопустимый статус оффера: %', p_new_status USING ERRCODE = 'P0006';
  END IF;

  UPDATE mentor_offers
  SET status = p_new_status,
      updated_at = now()
  WHERE offer_id = p_offer_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Оффер % не найден.', p_offer_id USING ERRCODE = 'P0002';
  END IF;

  INSERT INTO messages (booking_id, author_id, body)
  SELECT b.booking_id, o.mentor_id,
         format('Статус оффера %s изменён на %s в %s', p_offer_id::text, p_new_status, to_char(now(), 'YYYY-MM-DD HH24:MI:SS'))
  FROM bookings b
  JOIN mentor_offers o ON o.offer_id = b.offer_id
  WHERE o.offer_id = p_offer_id
  LIMIT 1;
EXCEPTION
  WHEN OTHERS THEN
    RAISE NOTICE 'Ошибка обновления статуса: %', SQLERRM;
    RAISE;
END;
$$;

-- 2. Триггеры -----------------------------------------------------------------------

-- 2.1 BEFORE INSERT ON bookings: автозаполнение цены/валюты и доп.валидация
DROP TRIGGER IF EXISTS trg_bookings_fill_price ON bookings;
DROP FUNCTION IF EXISTS trg_fn_bookings_fill_price();
CREATE OR REPLACE FUNCTION trg_fn_bookings_fill_price()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  v_offer mentor_offers%ROWTYPE;
BEGIN
  SELECT * INTO v_offer FROM mentor_offers WHERE offer_id = NEW.offer_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Нельзя создать бронирование без оффера %.', NEW.offer_id;
  END IF;

  IF NEW.currency IS NULL THEN
    NEW.currency := v_offer.currency;
  END IF;

  IF NEW.price_total IS NULL THEN
    NEW.price_total := ROUND((v_offer.hourly_rate / 60) * EXTRACT(EPOCH FROM (NEW.ends_at - NEW.starts_at)) / 60, 2);
  END IF;

  RETURN NEW;
END;
$$;
CREATE TRIGGER trg_bookings_fill_price
BEFORE INSERT ON bookings
FOR EACH ROW EXECUTE FUNCTION trg_fn_bookings_fill_price();

-- 2.2 AFTER INSERT ON messages: пишем аудит
DROP TRIGGER IF EXISTS trg_messages_audit ON messages;
DROP FUNCTION IF EXISTS trg_fn_messages_audit();
CREATE OR REPLACE FUNCTION trg_fn_messages_audit()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO booking_message_audit (message_id, booking_id, author_id, body_preview)
  VALUES (NEW.message_id, NEW.booking_id, NEW.author_id, LEFT(NEW.body, 200));
  RETURN NEW;
END;
$$;
CREATE TRIGGER trg_messages_audit
AFTER INSERT ON messages
FOR EACH ROW EXECUTE FUNCTION trg_fn_messages_audit();

-- 2.3 AFTER INSERT OR UPDATE ON session_feedbacks: пересчёт кэша рейтингов
DROP TRIGGER IF EXISTS trg_feedbacks_rating_cache ON session_feedbacks;
DROP FUNCTION IF EXISTS trg_fn_feedbacks_rating_cache();
CREATE OR REPLACE FUNCTION trg_fn_feedbacks_rating_cache()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO mentor_rating_cache AS mrc (mentor_id, feedback_count, avg_rating, updated_at)
  SELECT NEW.target_id,
         COUNT(*),
         ROUND(AVG(rating)::numeric, 2),
         now()
  FROM session_feedbacks
  WHERE target_id = NEW.target_id
  GROUP BY target_id
  ON CONFLICT (mentor_id) DO UPDATE
    SET feedback_count = EXCLUDED.feedback_count,
        avg_rating = EXCLUDED.avg_rating,
        updated_at = now();
  RETURN NEW;
END;
$$;
CREATE TRIGGER trg_feedbacks_rating_cache
AFTER INSERT OR UPDATE ON session_feedbacks
FOR EACH ROW EXECUTE FUNCTION trg_fn_feedbacks_rating_cache();

-- 3. Примеры использования -----------------------------------------------------------

-- 3.1 Создаём бронирование с помощью функции (50 минут DevOps)
DO $$
DECLARE
  v_offer_id BIGINT;
  v_existing_booking BIGINT;
  v_new_booking BIGINT;
  v_start_time CONSTANT TIMESTAMP := TIMESTAMP '2024-04-01 09:00';
  v_duration_min CONSTANT INTEGER := 50;
BEGIN
  SELECT o.offer_id
  INTO v_offer_id
  FROM mentor_offers o
  JOIN users u ON u.user_id = o.mentor_id
  JOIN skills s ON s.skill_id = o.skill_id
  WHERE u.username = 'mentor_ivan' AND s.name = 'DevOps'
  LIMIT 1;

  IF v_offer_id IS NULL THEN
    RAISE NOTICE 'Не найден DevOps оффер для mentor_ivan — пропускаем пример 3.1.';
    RETURN;
  END IF;

  SELECT b.booking_id
  INTO v_existing_booking
  FROM bookings b
  JOIN users mentee ON mentee.user_id = b.mentee_id
  WHERE mentee.username = 'mentee_alex'
    AND tsrange(b.starts_at, b.ends_at) && tsrange(v_start_time, v_start_time + (v_duration_min || ' minutes')::interval)
    AND b.status IN ('pending','approved','completed')
  ORDER BY b.booking_id DESC
  LIMIT 1;

  IF v_existing_booking IS NOT NULL THEN
    RAISE NOTICE 'Бронирование уже существует (id=%) — пример 3.1 пропущен.', v_existing_booking;
  ELSE
    v_new_booking := fn_create_booking(
      p_offer_id => v_offer_id,
      p_mentee_username => 'mentee_alex',
      p_starts_at => v_start_time,
      p_duration_min => v_duration_min
    );
    RAISE NOTICE 'Создано бронирование % в рамках примера 3.1.', v_new_booking;
  END IF;
END;
$$;

-- 3.2 Попытка создать пересекающееся бронирование — ожидаем ошибку бизнес-логики
DO $$
BEGIN
  PERFORM fn_create_booking(
    p_offer_id => (SELECT offer_id FROM mentor_offers o JOIN users u ON u.user_id = o.mentor_id
                   WHERE u.username = 'mentor_lucas' LIMIT 1),
    p_mentee_username => 'mentee_alex',
    p_starts_at => TIMESTAMP '2024-04-01 09:30',
    p_duration_min => 30);
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'Ожидаемая ошибка: %', SQLERRM;
END;
$$;

-- 3.3 Смена статуса оффера
DO $$
DECLARE
  v_offer_id BIGINT;
BEGIN
  SELECT o.offer_id
  INTO v_offer_id
  FROM mentor_offers o
  JOIN users u ON u.user_id = o.mentor_id
  WHERE u.username = 'mentor_lucas' AND o.status <> 'archived'
  LIMIT 1;

  IF v_offer_id IS NULL THEN
    RAISE NOTICE 'Нет подходящего оффера для обновления статуса.';
  ELSE
    CALL sp_update_offer_status(p_offer_id => v_offer_id, p_new_status => 'paused');
  END IF;
END;
$$;

-- 3.4 Добавление сообщения и проверка аудита
INSERT INTO messages (booking_id, author_id, body)
SELECT b.booking_id, b.mentee_id, 'Подтверждаю детали консультации.'
FROM bookings b
JOIN users u ON u.user_id = b.mentee_id AND u.username = 'mentee_daria'
ORDER BY b.booking_id DESC LIMIT 1;

SELECT * FROM booking_message_audit ORDER BY audit_id DESC LIMIT 3;

-- 3.5 Добавление отзыва для проверки кэша рейтингов
INSERT INTO session_feedbacks (session_id, author_id, target_id, rating, comment)
SELECT s.session_id, b.mentee_id, o.mentor_id, 4, 'Полезная новая встреча.'
FROM sessions s
JOIN bookings b ON b.booking_id = s.booking_id
JOIN mentor_offers o ON o.offer_id = b.offer_id
ORDER BY s.session_id DESC LIMIT 1
ON CONFLICT (session_id, author_id) DO NOTHING;

SELECT mentor_id, feedback_count, avg_rating FROM mentor_rating_cache;

-- 3.6 Получение аналитики по ментору
SELECT * FROM fn_get_mentor_stats('mentor_anna');

SELECT 'Лабораторная работа 3 завершена.' AS info;
