class CreateDevices < ActiveRecord::Migration[8.1]
  def change
    create_table :devices do |t|
      t.string :name, null: false
      t.string :slug, null: false
      t.json :capabilities, default: {}
      t.datetime :last_heartbeat_at

      t.timestamps
    end
    add_index :devices, :slug, unique: true
  end
end
