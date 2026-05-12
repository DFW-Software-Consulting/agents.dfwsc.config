#!/usr/bin/env node

import { createRequire } from "node:module";
import { homedir } from "node:os";
import process from "node:process";

const requireFromProject = createRequire(`${process.cwd()}/package.json`);
const requireFromConfig = createRequire(`${homedir()}/.config/opencode/package.json`);
const requireFromTool = createRequire(import.meta.url);

const blockedTokens = [
  "alter",
  "analyze",
  "attach",
  "call",
  "copy",
  "create",
  "delete",
  "detach",
  "do",
  "drop",
  "execute",
  "grant",
  "insert",
  "merge",
  "reindex",
  "replace",
  "reset",
  "revoke",
  "set",
  "truncate",
  "update",
  "upsert",
  "vacuum",
];

function printUsage() {
  console.error(`Usage:
  node ~/.config/opencode/tools/db-readonly.mjs --driver postgres --url "$DATABASE_URL" --sql "select * from users limit 5"
  node ~/.config/opencode/tools/db-readonly.mjs --driver mysql --url "$DATABASE_URL" --sql "show tables"
  node ~/.config/opencode/tools/db-readonly.mjs --driver sqlite --url ./dev.db --sql "select * from users limit 5"
  node ~/.config/opencode/tools/db-readonly.mjs --driver mssql --url "$DATABASE_URL" --sql "select top 5 * from Users"

Supported drivers: postgres, mysql, sqlite, mssql
Only read-only statements are accepted.`);
}

function parseArgs(argv) {
  const args = {};
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (!arg.startsWith("--")) continue;
    const key = arg.slice(2);
    const value = argv[index + 1];
    if (!value || value.startsWith("--")) {
      args[key] = "true";
    } else {
      args[key] = value;
      index += 1;
    }
  }
  return args;
}

function loadPackage(name) {
  try {
    return requireFromProject(name);
  } catch {
    try {
      return requireFromConfig(name);
    } catch {
      return requireFromTool(name);
    }
  }
}

function stripComments(sql) {
  return sql
    .replace(/--.*$/gm, "")
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .trim();
}

function validateReadOnly(sql) {
  const stripped = stripComments(sql);
  if (!stripped) throw new Error("SQL query is empty.");

  const statements = stripped
    .split(";")
    .map((statement) => statement.trim())
    .filter(Boolean);

  if (statements.length !== 1) {
    throw new Error("Only one SQL statement is allowed.");
  }

  const statement = statements[0];
  const firstToken = statement.match(/^\s*([a-zA-Z]+)/)?.[1]?.toLowerCase();
  const allowedStarters = new Set(["select", "with", "show", "describe", "desc", "explain", "pragma"]);

  if (!firstToken || !allowedStarters.has(firstToken)) {
    throw new Error("Only read-only SQL statements are allowed.");
  }

  const lowered = statement.toLowerCase();
  for (const token of blockedTokens) {
    const pattern = new RegExp(`(^|[^a-z0-9_])${token}([^a-z0-9_]|$)`, "i");
    if (pattern.test(lowered)) {
      throw new Error(`Blocked non-read-only SQL token: ${token}`);
    }
  }

  return statement;
}

function outputRows(rows) {
  console.log(JSON.stringify(rows, null, 2));
}

async function queryPostgres(url, sql) {
  const { Client } = loadPackage("pg");
  const client = new Client({ connectionString: url });
  await client.connect();
  try {
    await client.query("BEGIN READ ONLY");
    const result = await client.query(sql);
    await client.query("ROLLBACK");
    outputRows(result.rows);
  } catch (error) {
    await client.query("ROLLBACK").catch(() => {});
    throw error;
  } finally {
    await client.end();
  }
}

async function queryMysql(url, sql) {
  const mysql = loadPackage("mysql2/promise");
  const connection = await mysql.createConnection(url);
  try {
    await connection.query("SET TRANSACTION READ ONLY");
    await connection.query("START TRANSACTION");
    const [rows] = await connection.query(sql);
    await connection.query("ROLLBACK");
    outputRows(rows);
  } catch (error) {
    await connection.query("ROLLBACK").catch(() => {});
    throw error;
  } finally {
    await connection.end();
  }
}

async function querySqlite(url, sql) {
  const Database = loadPackage("better-sqlite3");
  const db = new Database(url, { readonly: true, fileMustExist: true });
  try {
    outputRows(db.prepare(sql).all());
  } finally {
    db.close();
  }
}

async function queryMssql(url, sql) {
  const mssql = loadPackage("mssql");
  const pool = await mssql.connect(url);
  const transaction = new mssql.Transaction(pool);
  try {
    await transaction.begin(mssql.ISOLATION_LEVEL.READ_COMMITTED);
    const request = new mssql.Request(transaction);
    const result = await request.query(sql);
    await transaction.rollback();
    outputRows(result.recordset ?? []);
  } catch (error) {
    await transaction.rollback().catch(() => {});
    throw error;
  } finally {
    await pool.close();
  }
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const driver = args.driver?.toLowerCase();
  const url = args.url ?? process.env.DATABASE_URL;
  const sql = args.sql;

  if (!driver || !url || !sql || args.help) {
    printUsage();
    process.exit(args.help ? 0 : 1);
  }

  const statement = validateReadOnly(sql);

  if (driver === "postgres" || driver === "postgresql" || driver === "pg") {
    await queryPostgres(url, statement);
    return;
  }

  if (driver === "mysql" || driver === "mariadb") {
    await queryMysql(url, statement);
    return;
  }

  if (driver === "sqlite" || driver === "sqlite3") {
    await querySqlite(url, statement);
    return;
  }

  if (driver === "mssql" || driver === "sqlserver") {
    await queryMssql(url, statement);
    return;
  }

  throw new Error(`Unsupported driver: ${driver}`);
}

main().catch((error) => {
  console.error(error.message);
  process.exit(1);
});
