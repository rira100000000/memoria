class CreatePresences < ActiveRecord::Migration[8.1]
  def change
    create_table :presences do |t|
      t.references :character, null: false, foreign_key: true, index: { unique: true }
      t.references :active_device, foreign_key: { to_table: :devices }
      t.datetime :since

      t.timestamps
    end
  end
end
