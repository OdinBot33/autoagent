# Task: Build a JSON Data Processor CLI

Create a Python command-line tool called `jproc.py` that:

1. Reads a JSON file from stdin or a file path argument
2. Supports these operations via flags:
   - `--keys` — list all top-level keys
   - `--flatten` — flatten nested objects with dot notation
   - `--filter KEY=VALUE` — filter array items where KEY equals VALUE
   - `--count` — count total items (if array) or keys (if object)
   - `--sort KEY` — sort array items by KEY

3. Outputs valid JSON to stdout

The tool must handle:
- Malformed JSON (print error to stderr, exit 1)
- Empty input
- Nested structures up to 5 levels deep
- Both arrays and objects as top-level types

Save the file as `/app/jproc.py` and make it executable.

Test data is available at `/app/data/test.json`.
