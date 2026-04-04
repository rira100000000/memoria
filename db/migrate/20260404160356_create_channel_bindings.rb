class CreateChannelBindings < ActiveRecord::Migration[8.1]
  def change
    create_table :channel_bindings do |t|
      t.references :character, null: false, foreign_key: true
      t.string :platform, null: false, default: "discord"  # discord, line, etc.
      t.string :channel_id, null: false                     # Discord channel ID

      t.timestamps
    end
    add_index :channel_bindings, [:platform, :channel_id], unique: true
  end
end
