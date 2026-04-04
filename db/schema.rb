# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_04_04_153446) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "api_usage_logs", force: :cascade do |t|
    t.bigint "character_id"
    t.datetime "created_at", null: false
    t.decimal "estimated_cost_usd", precision: 10, scale: 6, default: "0.0"
    t.integer "input_tokens", default: 0
    t.string "llm_model", null: false
    t.integer "output_tokens", default: 0
    t.integer "total_tokens", default: 0
    t.string "trigger_type", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["character_id"], name: "index_api_usage_logs_on_character_id"
    t.index ["trigger_type"], name: "index_api_usage_logs_on_trigger_type"
    t.index ["user_id", "created_at"], name: "index_api_usage_logs_on_user_id_and_created_at"
    t.index ["user_id"], name: "index_api_usage_logs_on_user_id"
  end

  create_table "characters", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.text "system_prompt"
    t.boolean "thinking_loop_enabled", default: false, null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.string "vault_dir_name", null: false
    t.index ["user_id"], name: "index_characters_on_user_id"
  end

  create_table "chat_results", force: :cascade do |t|
    t.bigint "character_id", null: false
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.text "error_message"
    t.string "job_id", null: false
    t.text "message", null: false
    t.text "response"
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.jsonb "usage"
    t.bigint "user_id", null: false
    t.index ["character_id"], name: "index_chat_results_on_character_id"
    t.index ["job_id"], name: "index_chat_results_on_job_id", unique: true
    t.index ["status"], name: "index_chat_results_on_status"
    t.index ["user_id"], name: "index_chat_results_on_user_id"
  end

  create_table "chat_sessions", force: :cascade do |t|
    t.bigint "character_id", null: false
    t.datetime "created_at", null: false
    t.string "full_log_path"
    t.datetime "last_message_at"
    t.jsonb "messages", default: [], null: false
    t.string "pending_timeout_job_id"
    t.string "status", default: "active", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["character_id", "user_id", "status"], name: "index_chat_sessions_on_character_id_and_user_id_and_status"
    t.index ["character_id"], name: "index_chat_sessions_on_character_id"
    t.index ["user_id"], name: "index_chat_sessions_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.string "api_token", null: false
    t.datetime "created_at", null: false
    t.integer "daily_budget_yen", default: 100
    t.string "email", null: false
    t.datetime "updated_at", null: false
    t.index ["api_token"], name: "index_users_on_api_token", unique: true
    t.index ["email"], name: "index_users_on_email", unique: true
  end

  add_foreign_key "api_usage_logs", "characters"
  add_foreign_key "api_usage_logs", "users"
  add_foreign_key "characters", "users"
  add_foreign_key "chat_results", "characters"
  add_foreign_key "chat_results", "users"
  add_foreign_key "chat_sessions", "characters"
  add_foreign_key "chat_sessions", "users"
end
