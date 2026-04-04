class CreateApiUsageLogs < ActiveRecord::Migration[8.1]
  def change
    create_table :api_usage_logs do |t|
      t.references :user, null: false, foreign_key: true
      t.references :character, foreign_key: true
      t.string :trigger_type, null: false  # user_message, thinking_loop, sleep_phase, tag_profiling, embedding
      t.string :llm_model, null: false
      t.integer :input_tokens, default: 0
      t.integer :output_tokens, default: 0
      t.integer :total_tokens, default: 0
      t.decimal :estimated_cost_usd, precision: 10, scale: 6, default: 0

      t.timestamps
    end
    add_index :api_usage_logs, :trigger_type
    add_index :api_usage_logs, [:user_id, :created_at]
  end
end
