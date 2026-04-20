---
name: database-migration
description: Database migration toolkit. Generate safe migrations, rollbacks, data validation for PostgreSQL, MySQL, SQLite, MongoDB. Zero-downtime patterns.
license: MIT
compatibility: universal
metadata:
  agents:
    - opencode
    - claude-code
    - cursor
    - copilot
    - cline
    - kilo
    - hermes
    - openclaw
  category: database
  tags:
    - database
    - migration
    - postgresql
    - mysql
    - sqlite
    - mongodb
    - schema
    - rollback
  version: 1.0.0
---

# Database Migration Skill

## Capabilities

Safe database migration solutions:

1. **Migration Generation**: Up/down migrations with rollback
2. **Schema Diffs**: Compare and sync database schemas
3. **Data Validation**: Pre/post migration data checks
4. **Zero-Downtime**: Blue-green, expand-contract patterns
5. **Multi-Database**: PostgreSQL, MySQL, SQLite, MongoDB

## Supported Databases

- **PostgreSQL**: 12+, with extensions
- **MySQL**: 5.7+, 8.0+
- **SQLite**: 3.x
- **MongoDB**: 4.4+, 5.0+

## Commands

- `generate migration` - Create up/down migration files
- `create rollback` - Generate rollback plan
- `validate data` - Pre/post migration validation
- `diff schemas` - Compare two schemas
- `zero-downtime plan` - Blue-green migration strategy

## Examples

See EXAMPLES.md for detailed usage examples.
