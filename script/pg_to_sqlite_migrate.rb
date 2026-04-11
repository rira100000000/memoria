#!/usr/bin/env ruby
# frozen_string_literal: true
#
# One-shot migration: PostgreSQL `memoria_development` → SQLite `storage/development.sqlite3`
#
# Usage:
#   ruby script/pg_to_sqlite_migrate.rb
#
# Environment overrides:
#   PG_DBNAME=other_db SQLITE_PATH=storage/something.sqlite3
#
# 注意:
# - 実行前に Memoria のプロセス (rails server / discord_bot) を全部止めること
# - 実行前に SQLite 側で `bin/rails db:migrate` が完了していること (空テーブルがあること)
# - 既存の SQLite データは全部 DELETE してから流し込むので、再実行で完全リセット
# - bundler/inline で Memoria の Gemfile から独立して pg / sqlite3 を取り込む

require "bundler/inline"

gemfile do
  source "https://rubygems.org"
  gem "pg", "~> 1.6"
  gem "sqlite3", "~> 2.9"
  gem "bigdecimal"
end

require "pg"
require "sqlite3"
require "json"
require "time"
require "bigdecimal"

PG_DBNAME   = ENV.fetch("PG_DBNAME", "memoria_development")
SQLITE_PATH = ENV.fetch("SQLITE_PATH", "storage/development.sqlite3")

# FK 順 (依存先が先)
TABLES = %w[
  users
  characters
  api_usage_logs
  channel_bindings
  chat_results
  chat_sessions
  reading_progresses
  scheduled_wakeups
].freeze

abort "Target SQLite #{SQLITE_PATH} not found. Run `bin/rails db:migrate` first." unless File.exist?(SQLITE_PATH)

pg = PG.connect(dbname: PG_DBNAME)
pg.type_map_for_results = PG::BasicTypeMapForResults.new(pg)

sqlite = SQLite3::Database.new(SQLITE_PATH)
sqlite.results_as_hash = false

puts "Source: postgresql:///#{PG_DBNAME}"
puts "Target: #{SQLITE_PATH}"
puts

def coerce_for_sqlite(value)
  case value
  when Hash, Array
    JSON.generate(value)
  when true
    1
  when false
    0
  when Time, DateTime
    # SQLite expects ISO 8601 in UTC for datetime columns
    value.utc.strftime("%Y-%m-%d %H:%M:%S.%6N")
  when BigDecimal
    value.to_s("F")
  else
    value
  end
end

sqlite.execute("PRAGMA foreign_keys = OFF")
sqlite.transaction do
  TABLES.each do |table|
    # SQLite 側に存在するカラムだけを転送対象にする (PG 側に dead column が残っていても無視)
    sqlite_cols = sqlite.execute("PRAGMA table_info(#{table})").map { |row| row[1] }
    if sqlite_cols.empty?
      puts "  #{table.ljust(22)} skip (no such table in SQLite)"
      next
    end

    col_list = sqlite_cols.join(", ")
    pg_rows = pg.exec("SELECT #{col_list} FROM #{table} ORDER BY id")
    if pg_rows.ntuples.zero?
      puts "  #{table.ljust(22)} 0 rows (skip)"
      next
    end

    cols = pg_rows.fields
    placeholders = (["?"] * cols.size).join(", ")
    sqlite.execute("DELETE FROM #{table}")

    insert_sql = "INSERT INTO #{table} (#{cols.join(', ')}) VALUES (#{placeholders})"
    statement = sqlite.prepare(insert_sql)

    pg_rows.each do |row|
      values = cols.map { |col| coerce_for_sqlite(row[col]) }
      statement.execute(values)
    end
    statement.close

    # SQLite の sqlite_sequence (autoincrement の最大値) を PG の最大 ID に合わせる
    max_id = sqlite.execute("SELECT MAX(id) FROM #{table}").first.first
    sqlite.execute("UPDATE sqlite_sequence SET seq = ? WHERE name = ?", [max_id, table]) if max_id

    puts "  #{table.ljust(22)} #{pg_rows.ntuples} rows  (max id #{max_id})"
  end
end

puts
puts "Verifying foreign keys..."
errors = sqlite.execute("PRAGMA foreign_key_check")
if errors.any?
  puts "  FK violations:"
  errors.each { |e| puts "    #{e.inspect}" }
  abort "Migration left FK violations behind. SQLite is in an inconsistent state."
end
sqlite.execute("PRAGMA foreign_keys = ON")
puts "  OK"

# 軽い sanity check
puts
puts "Row counts after migration:"
TABLES.each do |table|
  count = sqlite.execute("SELECT COUNT(*) FROM #{table}").first.first
  puts "  #{table.ljust(22)} #{count}"
end

pg.close
sqlite.close

puts
puts "Done."
