class CreateAdminKeys < ActiveRecord::Migration[8.1]
  def change
    create_table :admin_keys do |t|
      t.string :key_hash, null: false
      t.string :label
      t.datetime :revoked_at
      t.datetime :last_used_at

      t.timestamps
    end
    add_index :admin_keys, :key_hash, unique: true
  end
end
