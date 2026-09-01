# Database Migration Skill

Safe database migration toolkit. Generate migration scripts, rollback plans, data validation, and schema diffs for PostgreSQL, MySQL, SQLite, MongoDB.

## Features

- **Migration Generation**: Auto-generate up/down migrations
- **Rollback Plans**: Safe rollback strategies
- **Data Validation**: Pre/post migration validation
- **Schema Diffs**: Compare and sync schemas
- **Zero-Downtime**: Blue-green migration patterns

## Installation

```bash
git clone https://github.com/Yazz39/database-migration.git
cd database-migration
cp -r skills/* ~/.config/opencode/skills/
```

## Usage

Ask your AI agent:
- "Generate migration to add users table"
- "Create rollback plan for this migration"
- "Validate data before migration"
- "Compare production and staging schemas"

## Also in this repo

### RackNerd VPS API (`racknerd/`)

A zero-dependency CLI for controlling a RackNerd VPS through the SolusVM
client API — status, power actions, hostname, root password, serial console.
Credentials live in the environment, never in the repo.

```bash
export RACKNERD_API_URL="https://<panel-host>/api/client/command.php"
export RACKNERD_API_KEY="..."
export RACKNERD_API_HASH="..."
python3 racknerd/racknerd.py test
```

See [racknerd/README.md](racknerd/README.md) for full usage.

## License

MIT
