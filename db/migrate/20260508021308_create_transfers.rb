class CreateTransfers < ActiveRecord::Migration[8.1]
  def change
    create_table :transfers do |t|
      t.references :character, null: false, foreign_key: true
      t.references :from_device, foreign_key: { to_table: :devices }
      t.references :to_device, null: false, foreign_key: { to_table: :devices }
      t.string :reason
      t.datetime :occurred_at, null: false

      t.timestamps
    end
    add_index :transfers, [:character_id, :occurred_at]
  end
end
