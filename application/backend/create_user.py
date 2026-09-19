"""Create a NovaTech user. There is deliberately no public sign-up endpoint:
this is an internal tool, so accounts are created by an operator.

    docker compose exec api python create_user.py
"""

import getpass
import sys

import auth
import db

MIN_PASSWORD_LENGTH = 12


def main() -> int:
    name = input("Name: ").strip()
    email = input("Email: ").strip().lower()
    password = getpass.getpass(f"Password (min {MIN_PASSWORD_LENGTH} chars): ")

    if not name or "@" not in email:
        print("A name and a valid email are required.", file=sys.stderr)
        return 1
    if len(password) < MIN_PASSWORD_LENGTH:
        print(f"Password must be at least {MIN_PASSWORD_LENGTH} characters.", file=sys.stderr)
        return 1
    if getpass.getpass("Confirm password: ") != password:
        print("Passwords do not match.", file=sys.stderr)
        return 1

    db.pool.open()
    try:
        user = db.create_user(name, email, auth.hash_password(password))
    except db.Conflict as exc:
        print(exc, file=sys.stderr)
        return 1
    finally:
        db.pool.close()

    print(f"Created user id={user['id']} email={user['email']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
