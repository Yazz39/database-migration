# Setup Guide

## Global Installation

```bash
# OpenCode, Hermes
cp -r skills/database-migration ~/.config/opencode/skills/

# Claude Code, OpenClaw, Cline, Kilo
cp -r skills/database-migration ~/.claude/skills/

# Project-local
cp -r skills/database-migration ./.opencode/skills/
```

## Verification

Ask your AI agent: "What databases do you support for migrations?"

Expected response should list PostgreSQL, MySQL, SQLite, MongoDB.

## Configuration

No configuration required. Skill works out of the box.

## Updating

```bash
cd database-migration
git pull
cp -r skills/* ~/.config/opencode/skills/
```
