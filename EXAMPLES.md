# Examples

## PostgreSQL Migration

**Up Migration:**
```sql
-- Migration: 20240101_create_users_table
-- Created: 2024-01-01

BEGIN;

CREATE TABLE users (
    id SERIAL PRIMARY KEY,
    email VARCHAR(255) UNIQUE NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_users_email ON users(email);

CREATE TRIGGER update_users_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

COMMIT;
```

**Down Migration:**
```sql
-- Rollback: 20240101_create_users_table

BEGIN;

DROP TRIGGER IF EXISTS update_users_updated_at ON users;
DROP INDEX IF EXISTS idx_users_email;
DROP TABLE IF EXISTS users;

COMMIT;
```

## MySQL Migration

**Up Migration:**
```sql
-- Migration: add_user_status_column

ALTER TABLE users 
ADD COLUMN status ENUM('active', 'inactive', 'pending') DEFAULT 'pending';

ALTER TABLE users 
ADD INDEX idx_status (status);
```

**Down Migration:**
```sql
-- Rollback: add_user_status_column

ALTER TABLE users 
DROP INDEX idx_status;

ALTER TABLE users 
DROP COLUMN status;
```

## MongoDB Migration

**Up Migration (JavaScript):**
```javascript
// Migration: 20240101_add_user_roles
// MongoDB migration script

db.users.updateMany(
  { roles: { $exists: false } },
  { $set: { roles: ['user'] } }
);

db.users.createIndex({ roles: 1 });
```

**Down Migration:**
```javascript
// Rollback: 20240101_add_user_roles

db.users.updateMany(
  { roles: { $exists: true } },
  { $unset: { roles: "" } }
);

db.users.dropIndex({ roles: 1 });
```

## Zero-Downtime Migration (Expand-Contract)

**Phase 1 - Expand:**
```sql
-- Add new column alongside old one
ALTER TABLE users ADD COLUMN new_email VARCHAR(255);

-- Create trigger to sync both columns
CREATE TRIGGER sync_email
    BEFORE INSERT OR UPDATE ON users
    FOR EACH ROW
    EXECUTE FUNCTION sync_email_columns();
```

**Phase 2 - Migrate Data:**
```sql
-- Backfill existing data
UPDATE users SET new_email = email WHERE new_email IS NULL;
```

**Phase 3 - Contract:**
```sql
-- Remove old column
ALTER TABLE users DROP COLUMN email;
ALTER TABLE users RENAME COLUMN new_email TO email;
```

## Data Validation Script

```sql
-- Pre-migration validation
SELECT 
    COUNT(*) as total_rows,
    COUNT(email) as non_null_emails,
    COUNT(DISTINCT email) as unique_emails
FROM users;

-- Check for invalid emails
SELECT COUNT(*) as invalid_emails
FROM users
WHERE email !~ '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$';
```

## Schema Diff Example

```bash
# Compare production and staging
pgdiff --source production --target staging --output diff.sql

# Generated diff.sql:
ALTER TABLE users ADD COLUMN phone VARCHAR(20);
CREATE INDEX idx_users_phone ON users(phone);
```
