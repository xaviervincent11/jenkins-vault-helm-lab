import os

from flask import Flask

app = Flask(__name__)


@app.route("/")
def index():
    db_user = os.getenv("DB_USER", "missing")
    password_present = "yes" if os.getenv("DB_PASSWORD") else "no"
    return f"DB_USER={db_user}\nDB_PASSWORD_PRESENT={password_present}\n"


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)

