class CreateDeviceKeys < ActiveRecord::Migration[8.1]
  def change
    create_table :device_keys do |t|
      t.references :device, null: false, foreign_key: true
      t.string :key_hash, null: false
      t.string :label
      t.datetime :revoked_at
      t.datetime :last_used_at

      t.timestamps
    end
    add_index :device_keys, :key_hash, unique: true
    add_index :device_keys, [:device_id, :revoked_at]
  end
end
