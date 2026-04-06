FROM autoagent-base

RUN pip install flask --quiet

# Create a broken server with multiple bugs
RUN mkdir -p /app/data /logs

# Broken server.py (intentional bugs for the agent to find)
RUN cat > /app/server.py << 'PYEOF'
from flask import Flask, jsonify, request
import json
import os

app = Flask(__name_)  # Bug 1: wrong dunder

DATA_FILE = "/app/data/users.json"

def load_users():
    if os.path.exists(DATA_FILE):
        with open(DATA_FILE) as f:
            return json.load(f)
    return []

def save_users(users):
    with open(DATA_FILE, 'w') as f:
        json.dump(users, f)

@app.route('/')
def index():
    return jsonify({"status": "ok"})

@app.route('/users', methods=['GET'])
def get_users():
    users = load_users
    return jsonify(users)  # Bug 2: missing () on function call

@app.route('/users', methods=['POST'])
def add_user():
    data = request.get_json()
    users = load_users()
    new_user = {
        "id": len(users) + 1,
        "name": data["name"],
        "email": data["email"]
    }
    users.append(new_user)
    save_users(users)
    return jsonify(new_user), 201

@app.route('/users/<id>')  # Bug 3: id not cast to int
def get_user(id):
    users = load_users()
    for user in users:
        if user["id"] == id:  # Bug 4: comparing int to string
            return jsonify(user)
    return jsonify({"error": "not found"}), 404

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=500)  # Bug 5: wrong port
PYEOF

# Create initial data
RUN echo '[]' > /app/data/users.json

WORKDIR /app
