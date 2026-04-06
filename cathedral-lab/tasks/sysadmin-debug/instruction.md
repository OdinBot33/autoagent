# Task: Fix the Broken Web Server

A Python Flask web server at `/app/server.py` is broken. It should serve a REST API but has multiple issues.

Your job:
1. Read the server code and identify ALL bugs
2. Fix every bug
3. Ensure the server starts and responds correctly on port 5000
4. Create a health check script at `/app/healthcheck.sh` that verifies the server works

The server should handle:
- `GET /` — returns `{"status": "ok"}`
- `GET /users` — returns the users list from `/app/data/users.json`
- `POST /users` — adds a user (JSON body with "name" and "email")
- `GET /users/<id>` — returns a single user by ID

Start the server in the background and verify it works with your healthcheck script.
