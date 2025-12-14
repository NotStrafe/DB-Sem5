import asyncio
import os
import asyncpg
from dotenv import load_dotenv
from pathlib import Path

load_dotenv()

DB_CONFIG = {
    "dbname": os.getenv("DB_NAME"),
    "user": os.getenv("DB_USER"),
    "password": os.getenv("DB_PASS"),
    "host": os.getenv("DB_HOST"),
    "port": os.getenv("DB_PORT"),
}

SQL_PATH = Path("lab-1/mentorship_platform.sql")

if not SQL_PATH.exists():
    raise FileNotFoundError(f"SQL файл не найден: {SQL_PATH.resolve()}")
sql_text = SQL_PATH.read_text(encoding="utf-8")


async def connect_db(db_name: str):
    password = DB_CONFIG["password"] if DB_CONFIG["password"] != "" else None
    return await asyncpg.connect(user=DB_CONFIG["user"], password=password,
                                 host=DB_CONFIG["host"], port=DB_CONFIG["port"], database=db_name)


async def ensure_database():
    try:
        return await connect_db(DB_CONFIG["dbname"])
    except asyncpg.InvalidCatalogNameError:
        # БД нет — создаём её из postgres
        admin = await connect_db("postgres")
        try:
            await admin.execute(f"CREATE DATABASE '{DB_CONFIG['dbname']}';")
        finally:
            await admin.close()
        return await connect_db(DB_CONFIG["dbname"])


async def main():
    conn = await ensure_database()
    try:
        async with conn.transaction():
            await conn.execute(sql_text)

        # Проверка UQ 1:1 на sessions.booking_id
        uq = await conn.fetch("""
            SELECT pg_get_constraintdef(oid) AS def
            FROM pg_constraint
            WHERE conrelid = 'mentorship_platform.sessions'::regclass
              AND contype = 'u'
        """)
        print("UQ в sessions:", [r["def"] for r in uq] or "не найдено")
    finally:
        await conn.close()

if __name__ == "__main__":
    asyncio.run(main())
